#!/usr/bin/env python3
"""Give a surviving legacy .eml the name the live pipeline would write for it.

WHY
---
The pipeline switched to naming mail by the message (a k-token minted from the
message's own Message-ID and Date) instead of by the mailbox copy (the tail of the
Graph message id). Names are deterministic, so a message archived twice under the
same scheme overwrites itself - that is the property the sweeps and the dead-letter
replay rely on.

It does not hold ACROSS the schemes. A message archived before the switch sits under
`<stem> [<graph tail>].eml`; when anything re-archives it now, the pipeline computes
`<stem> [k<token>].eml`, sees no such blob, and writes a second copy of a message the
archive already has. Measured over a 17.5h window: ~300-430 new duplicates a day, all
of this one shape.

Renaming the legacy blob to the name the pipeline would write closes it at source.
The next write overwrites rather than duplicates, and no change to the archiving hot
path is needed - which matters, because the alternative was a per-message lookup on
the one path that must never lose mail.

It is also the option that does not trade away fidelity. The de-duplication keep-rule
prefers the legacy .eml because those are the bytes as delivered; the k-token copies
are re-exports. Renaming keeps the delivered bytes AND gains idempotency, where
switching the keep-rule would have bought idempotency with the bytes.

HOW THE TARGET NAME IS DERIVED, AND WHY IT IS NOT RE-DERIVED FROM THE SUBJECT
-----------------------------------------------------------------------------
The obvious approach - take the message's subject, run it through the pipeline's
sanitising chain, cap it, trim it - has to reproduce transform.ps1's 42-replace chain
exactly. Get one character wrong and the rename writes a name the pipeline will never
compute, creating a third copy instead of preventing a second.

None of that is necessary. The legacy blob's own name ALREADY contains that stem: the
same pipeline, the same chain, the same cap produced it. So the target is the source
name with only the bracketed identifier swapped. The stem is copied, never computed.

The one thing that could break that is the cap: the stem cap was lowered from 180 to
150, so a name written under the old cap would be longer than the pipeline would write
today. Measured over the live container - 297,076 legacy .eml names - the longest stem
is exactly 150 and none exceeds it. The concern is real but empirically void here, and
the plan re-checks it per name rather than trusting this paragraph.

WHAT IS DELIBERATELY LEFT ALONE
-------------------------------
  * attachments - a different layout, and not messages
  * blobs already named with a k-token - nothing to gain
  * legacy .msg - the pipeline writes .eml, so renaming a .msg to a k-token name
    still would not collide with what the pipeline computes. 829 of them; renaming
    them would achieve nothing for idempotency and is not this tool's job.
  * .eml with NO bracketed id at all (older subject-only names). Their stem cannot be
    told from a subject that merely ends in brackets - "... v. BHSI [100.141].eml" is
    a real name whose "[100.141]" is subject text, not an id. Guessing wrong produces
    a third copy. They need the subject from Graph to do safely, which is a different
    tool.
  * any message whose token cannot be minted - no Message-ID or no parseable Date.
    It keeps its legacy name, which is exactly today's behaviour.

Renames are atomic. The account has hierarchical namespace enabled, so the ADLS Gen2
rename is a metadata operation on the DFS endpoint: no copy, no data movement, no
window where the message exists twice or not at all, and no soft-delete churn. That is
strictly safer than copy-verify-delete, which is what this would need on a flat
account.

`If-None-Match: *` is sent on every rename, so a target that somehow already exists is
refused rather than overwritten. That case means a post-switch duplicate was already
written; collapsing those two is the de-duplication tool's job, not this one's, so it
is recorded and skipped.

Dry run unless --execute.
"""
import argparse
import concurrent.futures
import importlib.util
import io
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
LISTING = os.path.join(HERE, 'archive-blobs.txt')
MANIFEST = os.path.join(HERE, 'rename-manifest.tsv')
CHECKPOINT = os.path.join(HERE, 'rename-done.log')

DFS = 'https://samatters.dfs.core.windows.net/matters/'
DFS_API = '2021-06-08'

# A blob name the live pipeline produced: <matter>/Emails/<stem> [<id>].eml
NAME = re.compile(r'^(?P<pre>[^/]+/Emails/)(?P<stem>.+?) \[(?P<id>[^\]]+)\]\.eml$', re.DOTALL)
KTOKEN = re.compile(r'^k[0-9a-f]{22}$')
# The identifier the pipeline appends is the tail of a Graph message id with '/'->'_',
# '+'->'-' and '=' stripped, or one of the older fixed-width hex ids. Both are 16-24 chars
# of [A-Za-z0-9_-]. A subject that merely ends in brackets - "[100.141]" - does not match,
# which is the point: treating that as an id would truncate a real stem.
PIPELINE_ID = re.compile(r'^[A-Za-z0-9_-]{16,24}$')
STEM_CAP = 150


def load(name, needed):
    path = os.path.join(HERE, name)
    if not os.path.exists(path):
        sys.exit(f'{name} is not beside this script; it owns the logic this tool reuses.')
    spec = importlib.util.spec_from_file_location(name.replace('-', '_')[:-3], path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for fn in needed:
        if not hasattr(mod, fn):
            sys.exit(f'{name} has no {fn}(); its interface changed and this tool needs '
                     f'updating rather than working around it.')
    return mod


def say(msg):
    print(msg, flush=True)


def target_name(blob, token):
    """The name the live pipeline would write for this message, or None to leave it alone.

    Returning None is always the safe answer: the blob keeps the name it has, which is
    exactly today's behaviour. Every refusal below is a case where producing a name would
    be worse than producing nothing.
    """
    if not token or not KTOKEN.match(token):
        return None
    if '/Attachments/' in blob:
        return None
    m = NAME.match(blob)
    if not m:
        return None
    ident = m.group('id')
    # Order matters: a k-token also satisfies PIPELINE_ID, so it has to be caught first.
    if KTOKEN.match(ident):
        return None
    if not PIPELINE_ID.match(ident):
        # Subject text that happens to end in brackets. Treating it as an id would cut a
        # real stem short and send the rename somewhere the pipeline never looks.
        return None
    stem = m.group('stem')
    # A stem written under the old 180 cap is longer than the pipeline would write today,
    # so swapping the bracket alone would still not be the name it computes.
    if len(stem) > STEM_CAP:
        return None
    new = f'{m.group("pre")}{stem} [{token}].eml'
    return None if new == blob else new


# ── plan ─────────────────────────────────────────────────────────────────────────────────

def candidates(listing, limit=None):
    """Legacy .eml message blobs, in listing order."""
    out = []
    probe = 'k' + '0' * 22            # a syntactically valid token, to test shape only
    with io.open(listing, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            b = line.rstrip('\r\n')
            if not b:
                continue
            if target_name(b, probe):
                out.append(b)
                if limit and len(out) >= limit:
                    break
    return out


def cmd_plan(args):
    key_mod = load('ingest-key.py', ('dedup_key', 'clean_mid', 'sent_utc'))
    plan_mod = load('dedup-plan.py', ('Storage', 'resolve_eml'))
    storage = plan_mod.Storage()

    if not os.path.exists(args.listing):
        sys.exit(f'{args.listing} does not exist. Build it with archive-identity.ps1 or let '
                 f'reconcile-missed.ps1 write one; do NOT use az storage blob list.')
    cands = candidates(args.listing, args.limit)
    say(f'{len(cands):,} legacy .eml blobs are candidates for renaming')
    if not cands:
        return 0

    lock = threading.Lock()
    state = {'done': 0, 'ok': 0, 'noid': 0, 'err': 0}
    started = time.time()
    rows = []

    def one(blob):
        token, mid, sent, _lm, err = plan_mod.resolve_eml(storage, key_mod, blob)
        new = target_name(blob, token) if token else None
        with lock:
            state['done'] += 1
            if new:
                state['ok'] += 1
                rows.append(('ok', blob, new, token, mid or '', sent or ''))
            elif err:
                state['err'] += 1
                rows.append(('error', blob, '', '', mid or '', err))
            else:
                # A token was minted but the name would not change, or the shape check
                # refused it. Recorded so the count reconciles rather than vanishing.
                state['noid'] += 1
                rows.append(('skip', blob, '', token or '', mid or '', sent or ''))
            if state['done'] % 2000 == 0 or state['done'] == len(cands):
                el = max(time.time() - started, 1)
                say(f'  {state["done"]:,}/{len(cands):,}  renamable {state["ok"]:,}  '
                    f'skipped {state["noid"]:,}  unreadable {state["err"]:,}  '
                    f'{state["done"] / el:.0f}/s  eta {(len(cands) - state["done"]) / max(state["done"] / el, 0.01) / 60:.0f}m')

    with concurrent.futures.ThreadPoolExecutor(args.parallel) as pool:
        list(pool.map(one, cands))

    tmp = args.out + '.tmp'
    with io.open(tmp, 'w', encoding='utf-8', newline='') as fh:
        fh.write('status\tblob\ttarget\ttoken\tmessageId\tsentOrError\n')
        for r in rows:
            fh.write('\t'.join(x.replace('\t', ' ') for x in r) + '\n')
    os.replace(tmp, args.out)

    # A target that two different messages both want is a collision: renaming both would
    # destroy one. It should be impossible - the token is the message's identity - so if it
    # happens the token is not doing its job and nothing should be renamed on that basis.
    seen, dupes = {}, 0
    for st, blob, new, *_ in rows:
        if st != 'ok':
            continue
        if new in seen:
            dupes += 1
            if dupes <= 5:
                say(f'  COLLISION {new}\n      {seen[new]}\n      {blob}')
        seen[new] = blob

    say(f'\nrenamable {state["ok"]:,}   skipped {state["noid"]:,}   '
        f'unreadable {state["err"]:,}   -> {args.out}')
    if dupes:
        say(f'{dupes:,} target name(s) claimed by more than one source - NOT safe to execute')
        return 1
    say('no target is claimed twice')
    return 0


# ── execute ──────────────────────────────────────────────────────────────────────────────

def rename_blob(storage, src, dst):
    """Atomic ADLS Gen2 rename. Returns (status, detail)."""
    def q(p):
        return '/'.join(urllib.parse.quote(s, safe='') for s in p.split('/'))

    req = urllib.request.Request(DFS + q(dst), method='PUT', data=b'')
    req.add_header('Authorization', f'Bearer {storage.token()}')
    req.add_header('x-ms-version', DFS_API)
    req.add_header('x-ms-rename-source', '/matters/' + q(src))
    req.add_header('Content-Length', '0')
    # Never overwrite. A target that exists is a post-switch duplicate, and collapsing
    # those two is the de-duplication tool's decision, not this one's.
    req.add_header('If-None-Match', '*')
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, ''
    except urllib.error.HTTPError as e:
        return e.code, (e.reason or '')
    except Exception as e:                                         # noqa: BLE001
        return 0, type(e).__name__


def cmd_execute(args):
    plan_mod = load('dedup-plan.py', ('Storage',))
    storage = plan_mod.Storage()

    if not os.path.exists(args.manifest):
        sys.exit(f'{args.manifest} does not exist - run `plan` first.')
    todo = []
    with io.open(args.manifest, encoding='utf-8') as fh:
        header = fh.readline()
        if not header.startswith('status\tblob\ttarget'):
            sys.exit(f'{args.manifest} is not a manifest produced by `plan`')
        for line in fh:
            p = line.rstrip('\n').split('\t')
            if len(p) >= 4 and p[0] == 'ok':
                todo.append((p[1], p[2], p[3]))

    done = set()
    if os.path.exists(args.checkpoint):
        with io.open(args.checkpoint, encoding='utf-8') as fh:
            for line in fh:
                q = line.rstrip('\n').split('\t')
                # Only a completed rename counts as done. A 409 or a network failure must
                # be retried, not silently treated as finished.
                if len(q) >= 2 and q[1] == '201':
                    done.add(q[0])
        say(f'checkpoint has {len(done):,} already renamed')

    todo = [t for t in todo if t[0] not in done]
    if args.limit:
        todo = todo[:args.limit]
    say(f'{len(todo):,} to rename this run')

    # Re-derive every target from its source rather than trusting the manifest's column.
    # The manifest is a file on disk that anything could have edited between plan and
    # execute; the rule is in this process.
    bad = [(s, t) for s, t, tok in todo if target_name(s, tok) != t]
    if bad:
        say(f'REFUSING: {len(bad)} manifest row(s) disagree with the naming rule, e.g.')
        for s, t in bad[:3]:
            say(f'  {s}\n    manifest says {t}')
        return 1
    say('every manifest row re-derives to the same target')

    if not args.execute:
        for s, t, _ in todo[:5]:
            say(f'  would rename {s}\n            -> {t}')
        say(f'\nDRY RUN: {len(todo):,} blobs would be renamed. Re-run with --execute to apply.')
        return 0

    lock = threading.Lock()
    state = {'done': 0, 'ok': 0, 'exists': 0, 'fail': 0}
    started = time.time()
    ck = io.open(args.checkpoint, 'a', encoding='utf-8')

    def one(item):
        src, dst, _tok = item
        status, detail = rename_blob(storage, src, dst)
        if status in (401, 403):
            storage.token(force=True)
            status, detail = rename_blob(storage, src, dst)
        with lock:
            state['done'] += 1
            if status == 201:
                state['ok'] += 1
            elif status == 409:
                state['exists'] += 1
            else:
                state['fail'] += 1
            ck.write(f'{src}\t{status}\t{dst}\t{detail}\n')
            if state['done'] % 250 == 0 or state['done'] == len(todo):
                ck.flush()
                el = max(time.time() - started, 1)
                say(f'  {state["done"]:,}/{len(todo):,}  renamed {state["ok"]:,}  '
                    f'target existed {state["exists"]:,}  failed {state["fail"]:,}  '
                    f'{state["done"] / el:.0f}/s')

    try:
        with concurrent.futures.ThreadPoolExecutor(args.parallel) as pool:
            list(pool.map(one, todo))
    finally:
        ck.flush()
        ck.close()

    say(f'renamed {state["ok"]:,}, target already existed {state["exists"]:,}, '
        f'failed {state["fail"]:,}')
    return 1 if state['fail'] else 0


# ── selftest ─────────────────────────────────────────────────────────────────────────────

def cmd_selftest(args):
    """Prove the name transformation refuses everything it should.

    Every failure mode here is silent in production: a wrong target name does not error,
    it writes a name the pipeline will never compute, and the duplicate this tool exists
    to prevent gets a third sibling instead.
    """
    fails = []

    def check(name, got, want):
        if got == want:
            print(f'  ok   {name}')
        else:
            print(f'  FAIL {name}\n         got  {got!r}\n         want {want!r}')
            fails.append(name)

    T = 'k' + '0' * 22
    print('target name:')
    # The stem is copied verbatim from the source, including punctuation the two write
    # paths disagree about. Re-deriving it is what this avoids.
    check('swaps a graph tail for the token',
          target_name('100.079/Emails/RE_ Claim No. 23-7025944 [TKHIWU4VNG_RAAL9PP9KAAA].eml', T),
          f'100.079/Emails/RE_ Claim No. 23-7025944 [{T}].eml')
    check('swaps an older hex id',
          target_name('100.222/Emails/Kemper 24123632008 [BBDF23435B973AD6578E0CA2].eml', T),
          f'100.222/Emails/Kemper 24123632008 [{T}].eml')
    check('keeps a stem that itself ends in brackets',
          target_name('100.141/Emails/Re_ 998 - Woo Jin Kim v. BHSI [100.141] [TKHIWU4VNG_RAALfZPnVAAA].eml', T),
          f'100.141/Emails/Re_ 998 - Woo Jin Kim v. BHSI [100.141] [{T}].eml')
    check('keeps a stem with an underscore-sanitised slash',
          target_name('140.043/Emails/Re_ CIG claim 2033962 _ FW_ Summons [TKHIWU4VNG_RAAMUG7].eml', T),
          f'140.043/Emails/Re_ CIG claim 2033962 _ FW_ Summons [{T}].eml')

    print('refusals:')
    # "[100.141]" is subject text, not an id. Stripping it would shorten a real stem and
    # send the rename to a name the pipeline never writes.
    check('no pipeline id - subject-only name',
          target_name('100.141/Emails/Re_ 998 - Woo Jin Kim v. BHSI [100.141].eml', T), None)
    check('no brackets at all',
          target_name('117.001/Emails/RE_ Written Discovery Objection Responses.eml', T), None)
    check('already k-named',
          target_name(f'100.079/Emails/RE_ Claim [{"k" + "a" * 22}].eml', T), None)
    # The pipeline writes .eml. Renaming a .msg to a k-token name still does not collide
    # with what it computes, so it buys nothing and is refused rather than done pointlessly.
    check('legacy .msg',
          target_name('100.079/Emails/RE_ Claim [TKHIWU4VNG_RAAL9PP9KAAA].msg', T), None)
    check('attachment path',
          target_name('100.079/Emails/Attachments/TKHIWU4VNG_RAAL/2026 MO.pdf', T), None)
    check('not under Emails',
          target_name('100.079/Docs/RE_ Claim [TKHIWU4VNG_RAAL9PP9KAAA].eml', T), None)
    # A malformed token must never reach a blob name.
    check('token is not a k-token', target_name(
        '100.079/Emails/RE_ Claim [TKHIWU4VNG_RAAL9PP9KAAA].eml', 'TKHIWU4VNG_RAAL'), None)
    check('token is empty',
          target_name('100.079/Emails/RE_ Claim [TKHIWU4VNG_RAAL9PP9KAAA].eml', ''), None)
    check('token is None',
          target_name('100.079/Emails/RE_ Claim [TKHIWU4VNG_RAAL9PP9KAAA].eml', None), None)
    # The stem cap fell 180 -> 150. A stem written under the old cap is longer than the
    # pipeline would write today, so swapping only the bracket would still miss.
    check('stem longer than the cap',
          target_name('100.079/Emails/' + ('x' * (STEM_CAP + 1)) + ' [TKHIWU4VNG_RAAL9PP9KAAA].eml', T),
          None)
    check('stem exactly at the cap',
          target_name('100.079/Emails/' + ('x' * STEM_CAP) + ' [TKHIWU4VNG_RAAL9PP9KAAA].eml', T),
          '100.079/Emails/' + ('x' * STEM_CAP) + f' [{T}].eml')
    # A rename must change the name. Producing the source path would be a no-op that the
    # executor would still spend a request on.
    src = f'100.079/Emails/RE_ Claim [{T}].eml'
    check('renaming to its own name', target_name(src, T), None)

    print()
    if fails:
        print(f'{len(fails)} control(s) misbehaved: {", ".join(fails)}')
        return 1
    print('all target-name controls behaved as specified.')
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('selftest', help='offline negative controls; no credentials needed')

    pl = sub.add_parser('plan', help='derive every target name and write the manifest')
    pl.add_argument('--listing', default=LISTING)
    pl.add_argument('--out', default=MANIFEST)
    pl.add_argument('--parallel', type=int, default=16)
    pl.add_argument('--limit', type=int)

    ex = sub.add_parser('execute', help='apply the manifest (dry run unless --execute)')
    ex.add_argument('--manifest', default=MANIFEST)
    ex.add_argument('--checkpoint', default=CHECKPOINT)
    ex.add_argument('--parallel', type=int, default=8)
    ex.add_argument('--limit', type=int)
    ex.add_argument('--execute', action='store_true')

    args = ap.parse_args()
    return {'selftest': cmd_selftest, 'plan': cmd_plan, 'execute': cmd_execute}[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
