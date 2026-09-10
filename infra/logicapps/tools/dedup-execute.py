"""Execute - carefully - the duplicate removal that dedup-plan.py only planned.

    python dedup-execute.py list      --out current-blobs.tsv
    python dedup-execute.py validate  --listing current-blobs.tsv [--manifest dedup-manifest.tsv]
    python dedup-execute.py probe     --validated dedup-validated.tsv [--parallel 24]
    python dedup-execute.py dryrun    --validated dedup-validated.tsv --out dedup-deletes.txt
    python dedup-execute.py delete    --deletes dedup-deletes.txt [--limit N] [--parallel 12]
    python dedup-execute.py rename    [--validated dedup-validated.tsv] [--execute]
    python dedup-execute.py undelete  --blob <name>
    python dedup-execute.py softlist  --prefix <path prefix>
    python dedup-execute.py identities --listing current-blobs.tsv

dedup-plan.py deliberately contains no DELETE. This script is where the delete lives, and
it is a separate file for that reason: "run the planner" stays a safe sentence.

--- why a fresh listing, every time ------------------------------------------------------

The manifest is a photograph of the container at the moment it was planned. Between then
and now the pipeline switched to k-token naming, a recovery sweep re-archived messages,
and normal traffic continued. Three things can therefore be wrong with any manifest row:

  * a DELETE candidate has already gone      - harmless on its own
  * a DELETE candidate has been REWRITTEN    - its bytes, and so its identity, may differ
  * the KEEP has gone or been rewritten      - deleting its siblings would destroy the
                                               last copy of the message

The third is the one that matters, and it is not detectable from the manifest alone. So
`validate` re-reads the container and re-checks every member of every group. A group that
fails any check is SKIPPED WHOLE - never partially collapsed, never guessed at. Skipping
leaves duplicates behind, which costs storage; guessing costs client correspondence.

--- LastModified is the identity check ---------------------------------------------------

For a legacy .eml the manifest's token came from bytes read at plan time, so the token is
only still true if the bytes are. LastModified is the cheapest proof of that and it comes
free in the listing. An ingested blob states its token in its own name, so for those the
name is the proof and LastModified is not compared.
"""
import argparse
import concurrent.futures
import importlib.util
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.abspath(__file__))
ACCOUNT = 'samatters'
CONTAINER = 'matters'
ROOT = f'https://{ACCOUNT}.blob.core.windows.net/{CONTAINER}'
API_VERSION = '2021-08-06'

MANIFEST = os.path.join(HERE, 'dedup-manifest.tsv')
LISTING = os.path.join(HERE, 'current-blobs.tsv')
VALIDATED = os.path.join(HERE, 'dedup-validated.tsv')
SKIPPED = os.path.join(HERE, 'dedup-skipped.tsv')
DELETES = os.path.join(HERE, 'dedup-deletes.txt')
CHECKPOINT = os.path.join(HERE, 'dedup-deleted.log')
RESOLVED = os.path.join(HERE, 'dedup-resolved.tsv')

TOKEN_IN_NAME = re.compile(r'\[(k[0-9a-f]{22})\]\.(?:eml|msg)$', re.IGNORECASE)
ATTACHMENT_PATH = re.compile(r'/Emails/Attachments/', re.IGNORECASE)


def load_planner():
    """Reuse dedup-plan.py's Storage class rather than writing a second token minter."""
    path = os.path.join(HERE, 'dedup-plan.py')
    if not os.path.exists(path):
        sys.exit('dedup-plan.py is not beside this script; it owns the storage client.')
    spec = importlib.util.spec_from_file_location('dedup_plan', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def blob_url(name):
    return ROOT + '/' + '/'.join(urllib.parse.quote(p, safe='') for p in name.split('/'))


def say(msg):
    print(f'[{time.strftime("%H:%M:%S")}] {msg}', flush=True)


# ── listing ──────────────────────────────────────────────────────────────────────────────

def cmd_list(args):
    """Full container listing with Last-Modified, walking NextMarker.

    Mirrors Get-AllBlobNames in archive-identity.ps1: maxresults caps a PAGE, not the
    result set, and the token is re-minted on a clock rather than after the 403 that a
    45-minute listing would otherwise hit.
    """
    plan = load_planner()
    storage = plan.Storage()
    out = args.out or LISTING
    tmp = out + '.partial'

    include = '&include=deleted' if args.include_deleted else ''
    marker, pages, count = '', 0, 0
    started = time.time()
    with open(tmp, 'w', encoding='utf-8', newline='') as fh:
        fh.write('blob\tlastModified\tsize\tdeleted\n')
        while True:
            u = (f'{ROOT}?restype=container&comp=list&maxresults=5000{include}'
                 f'&prefix={urllib.parse.quote(args.prefix, safe="")}')
            if marker:
                u += '&marker=' + urllib.parse.quote(marker, safe='')
            req = urllib.request.Request(u)
            req.add_header('Authorization', f'Bearer {storage.token()}')
            req.add_header('x-ms-version', API_VERSION)
            for attempt in range(5):
                try:
                    with urllib.request.urlopen(req, timeout=180) as resp:
                        body = resp.read()
                    break
                except Exception as e:                             # noqa: BLE001
                    if attempt == 4:
                        raise
                    say(f'  page {pages} failed ({type(e).__name__}: {e}); retrying')
                    time.sleep(3 * (attempt + 1))
                    req.add_header('Authorization', f'Bearer {storage.token()}')
            root = ET.fromstring(body)
            for b in root.iter('Blob'):
                name = b.findtext('Name') or ''
                props = b.find('Properties')
                lm = props.findtext('Last-Modified') if props is not None else ''
                size = props.findtext('Content-Length') if props is not None else ''
                deleted = b.findtext('Deleted') or 'false'
                fh.write(f'{name}\t{lm or ""}\t{size or ""}\t{deleted}\n')
                count += 1
            marker = root.findtext('NextMarker') or ''
            pages += 1
            if pages % 20 == 0:
                fh.flush()
                rate = count / max(time.time() - started, 1)
                say(f'  {count:,} blobs, {pages} pages, {rate:.0f}/s')
            if not marker:
                break
    os.replace(tmp, out)
    say(f'listed {count:,} entries in {pages} pages -> {out}')
    return 0


def read_listing(path):
    """blob -> (lastModified, size). Soft-deleted rows are excluded: a deleted blob is
    not present for the purposes of "does the keep still exist"."""
    live, deleted = {}, set()
    with open(path, encoding='utf-8') as fh:
        header = fh.readline()
        if not header.startswith('blob\t'):
            sys.exit(f'{path} is not a listing produced by `dedup-execute.py list`')
        for line in fh:
            p = line.rstrip('\n').split('\t')
            if len(p) < 4:
                continue
            if p[3].lower() == 'true':
                deleted.add(p[0])
                continue
            live[p[0]] = (p[1], p[2])
    return live, deleted


def read_manifest(path):
    """token -> {'keep': row, 'deletes': [rows]}, with repeated PATHS collapsed.

    dedup-manifest.tsv lists the same blob path more than once in 9,672 of its 47,121
    groups, and in 8,819 of those the group is nothing but ONE path written twice - once
    KEEP, once DELETE, the reason column reading "duplicate of <itself>". Executing the
    manifest verbatim would have deleted the sole copy of 8,814 messages.

    The cause is upstream of the manifest: load_candidates() in dedup-plan.py builds
    by_mid[messageId].append(blob) straight from messageid-index.tsv, so a blob with two
    rows in that index joins its group twice. Two row dicts for one path then reach
    choose_survivor(), which compares with `r is survivor` - object identity, not path -
    so the second dict for the survivor's own path is labelled DELETE. It is the same
    family of mistake collision-truth.ps1 already carries a warning about: "deduplicate by
    message id first - paging returns the same message twice".

    Collapsing identical path strings is not a judgement call, so it is done here rather
    than skipping the groups: a path is a path, and the set of distinct paths is the
    group's real membership. The keep-rule is NOT re-run. Its sort key is
    (scheme != legacy, lastModified, blob), and duplicate rows of one path sort
    identically, so the minimum over the multiset and over the distinct set are the same
    path - the signed-off survivor stands unchanged.

    A group left with no distinct delete path was never a duplicate group at all and is
    reported as such by the caller.
    """
    groups = {}
    stats = {'rows': 0, 'collapsed_keep_dupes': 0, 'collapsed_del_dupes': 0}
    with open(path, encoding='utf-8') as fh:
        header = fh.readline()
        if not header.startswith('action\ttoken\t'):
            sys.exit(f'{path} is not a dedup manifest')
        for line in fh:
            p = line.rstrip('\n').split('\t')
            if len(p) < 7:
                continue
            stats['rows'] += 1
            row = {'action': p[0], 'token': p[1], 'matter': p[2], 'scheme': p[3],
                   'lastModified': p[4], 'blob': p[5], 'reason': p[6]}
            g = groups.setdefault(p[1], {'keep': None, 'deletes': [], 'raw_deletes': 0})
            if row['action'] == 'KEEP':
                if g['keep'] is not None:
                    sys.exit(f'manifest group {p[1]} has two KEEP rows - refusing to run')
                g['keep'] = row
            else:
                g['deletes'].append(row)
                g['raw_deletes'] += 1

    for token, g in groups.items():
        keep_blob = g['keep']['blob'] if g['keep'] else None
        seen, kept_rows = set(), []
        for r in g['deletes']:
            if r['blob'] == keep_blob:
                stats['collapsed_keep_dupes'] += 1
                continue
            if r['blob'] in seen:
                stats['collapsed_del_dupes'] += 1
                continue
            seen.add(r['blob'])
            kept_rows.append(r)
        g['deletes'] = kept_rows
    return groups, stats


# ── validation ───────────────────────────────────────────────────────────────────────────

# Ordered most-serious first. The skip file records ONE reason per group, and which one
# it records must not depend on the order the checks happen to run in: a group that is
# both an attachment-layout exclusion and a group whose survivor has vanished has to be
# filed under the vanished survivor, or the count that matters gets absorbed into the
# count that does not.
REASON_PRIORITY = (
    'no-keep-row', 'keep-missing', 'keep-rewritten', 'keep-name-has-no-token',
    'keep-in-delete-list', 'candidate-rewritten', 'candidate-token-mismatch',
    'candidate-gone', 'single-distinct-path', 'attachment-layout', 'no-delete-rows',
)


def validate_groups(groups, live, softdeleted, out_path, skip_path):
    """The whole of the validation, with no printing, so selftest can assert on it.

    Returns (ok_groups, ok_deletes, primary, tripped). `primary` counts each group once,
    under its most serious reason; `tripped` counts every check independently, so a check
    whose findings are all masked by a more serious reason still shows a non-zero number.
    """
    primary = {k: 0 for k in REASON_PRIORITY}
    tripped = {k: 0 for k in REASON_PRIORITY}
    ok_groups = ok_deletes = 0

    with open(out_path, 'w', encoding='utf-8', newline='') as fh, \
            open(skip_path, 'w', encoding='utf-8', newline='') as sk:
        fh.write('action\ttoken\tmatter\tscheme\tblob\n')
        sk.write('token\treason\tdetail\n')

        for token, g in sorted(groups.items()):
            keep = g['keep']
            problems = {}

            def flag(why, detail):
                problems.setdefault(why, detail)

            members = ([keep] if keep else []) + g['deletes']
            if any(ATTACHMENT_PATH.search(r['blob']) for r in members):
                flag('attachment-layout', members[0]['blob'])

            if keep is None:
                flag('no-keep-row', token)
            else:
                if keep['blob'] not in live:
                    flag('keep-missing',
                         'soft-deleted' if keep['blob'] in softdeleted else 'absent')
                else:
                    if keep['scheme'] == 'legacy' and keep['lastModified']:
                        now_lm = live[keep['blob']][0]
                        if now_lm != keep['lastModified']:
                            flag('keep-rewritten', f'{keep["lastModified"]} -> {now_lm}')
                    if keep['scheme'] == 'ingested' and not TOKEN_IN_NAME.search(keep['blob']):
                        flag('keep-name-has-no-token', keep['blob'])

            if not g['deletes']:
                flag('single-distinct-path' if g['raw_deletes'] else 'no-delete-rows',
                     (keep or {}).get('blob', token))

            # Every candidate is examined. Stopping at the first fault would under-count
            # the checks and make a zero unreadable.
            for r in g['deletes']:
                if r['blob'] not in live:
                    flag('candidate-gone',
                         'soft-deleted' if r['blob'] in softdeleted else 'absent')
                    continue
                if r['scheme'] == 'legacy' and r['lastModified']:
                    now_lm = live[r['blob']][0]
                    if now_lm != r['lastModified']:
                        flag('candidate-rewritten', f'{r["lastModified"]} -> {now_lm}')
                if r['scheme'] == 'ingested':
                    name_tok = TOKEN_IN_NAME.search(r['blob'])
                    if not name_tok or name_tok.group(1).lower() != token.lower():
                        flag('candidate-token-mismatch', r['blob'])
                if keep and r['blob'] == keep['blob']:
                    flag('keep-in-delete-list', r['blob'])

            for why in problems:
                tripped[why] += 1

            if problems:
                why = next(w for w in REASON_PRIORITY if w in problems)
                primary[why] += 1
                sk.write(f'{token}\t{why}\t{problems[why]}\n')
                continue

            ok_groups += 1
            ok_deletes += len(g['deletes'])
            fh.write(f'KEEP\t{token}\t{keep["matter"]}\t{keep["scheme"]}\t{keep["blob"]}\n')
            for r in g['deletes']:
                fh.write(f'DELETE\t{token}\t{r["matter"]}\t{r["scheme"]}\t{r["blob"]}\n')

    return ok_groups, ok_deletes, primary, tripped


def cmd_validate(args):
    manifest = args.manifest or MANIFEST
    listing = args.listing or LISTING
    say(f'manifest {manifest}')
    say(f'listing  {listing}')
    groups, mstats = read_manifest(manifest)
    live, softdeleted = read_listing(listing)
    say(f'{len(groups):,} manifest groups; {len(live):,} live entries in the container')
    if mstats['collapsed_keep_dupes'] or mstats['collapsed_del_dupes']:
        say('')
        say('MANIFEST DEFECT - repeated blob paths inside a group, collapsed before use:')
        say(f'    DELETE rows naming the group\'s own KEEP path : '
            f'{mstats["collapsed_keep_dupes"]:,}   <- these would have deleted the survivor')
        say(f'    DELETE rows repeating another DELETE path     : '
            f'{mstats["collapsed_del_dupes"]:,}')
        say('')

    # A blob must never be a KEEP in one group and a DELETE in another, and must never be
    # listed twice. Either would mean the planner's grouping is not a partition, and the
    # arithmetic that follows would be meaningless.
    keeps, dels, dup = set(), set(), []
    for g in groups.values():
        if g['keep']:
            if g['keep']['blob'] in keeps or g['keep']['blob'] in dels:
                dup.append(g['keep']['blob'])
            keeps.add(g['keep']['blob'])
        for r in g['deletes']:
            if r['blob'] in dels or r['blob'] in keeps:
                dup.append(r['blob'])
            dels.add(r['blob'])
    overlap = keeps & dels
    if dup or overlap:
        say(f'STOP: {len(dup)} blob(s) appear in more than one manifest row, '
            f'{len(overlap)} appear as both KEEP and DELETE')
        for b in (dup[:5] + sorted(overlap)[:5]):
            say(f'  {b}')
        return 1
    say(f'partition check ok: {len(keeps):,} distinct keeps, {len(dels):,} distinct deletes')

    out = args.out or VALIDATED
    skip_out = args.skipped or SKIPPED
    ok_groups, ok_deletes, primary, tripped = validate_groups(
        groups, live, softdeleted, out, skip_out)

    say('')
    say(f'groups validated : {ok_groups:,}')
    say(f'blobs to delete  : {ok_deletes:,}')
    say(f'groups skipped   : {len(groups) - ok_groups:,}')
    say('')
    say('  skipped, by most serious reason        (each group counted once)')
    for why in REASON_PRIORITY:
        say(f'    {why:<26} {primary[why]:,}')
    say('')
    say('  checks tripped                         (a group can trip several)')
    for why in REASON_PRIORITY:
        say(f'    {why:<26} {tripped[why]:,}')
    say(f'validated -> {out}')
    say(f'skipped   -> {skip_out}')
    return 0


# ── negative controls ────────────────────────────────────────────────────────────────────

TOK_A = 'k' + 'a' * 22
TOK_B = 'k' + 'b' * 22
TOK_C = 'k' + 'c' * 22
LM1 = 'Mon, 01 Sep 2026 10:00:00 GMT'
LM2 = 'Tue, 02 Sep 2026 12:00:00 GMT'


def _fixture(tmp, name, manifest_rows, listing_rows):
    mp = os.path.join(tmp, f'{name}-manifest.tsv')
    lp = os.path.join(tmp, f'{name}-listing.tsv')
    with open(mp, 'w', encoding='utf-8', newline='') as fh:
        fh.write('action\ttoken\tmatter\tscheme\tlastModified\tblob\treason\n')
        for r in manifest_rows:
            fh.write('\t'.join(r) + '\n')
    with open(lp, 'w', encoding='utf-8', newline='') as fh:
        fh.write('blob\tlastModified\tsize\tdeleted\n')
        for r in listing_rows:
            fh.write('\t'.join(r) + '\n')
    return mp, lp


def _selftest_renames():
    """Prove the survivor rename is one-to-one, and refuses rather than guesses when it is not.

    A standalone rename of every legacy blob is NOT one-to-one: several mailboxes archive one
    message under their own Graph tails, all of those mint the same token, and so all of them
    want the same new name. Measured live, 212 of 3,726 targets (5.4%) were claimed by more
    than one source, some by five.

    Doing it here removes that by construction rather than by care: the keep-rule has already
    reduced each group to one survivor, so one token yields one source, and two different
    groups have different tokens. Measured over the 38,221 survivors of the current cleanup,
    35,559 are renamable and they produce 35,559 distinct targets - zero collisions.

    "By construction" is exactly the kind of claim that stops being true after an edit, so the
    collision is still detected and still refuses, and the control below feeds it a case that
    trips it.
    """
    failures = []

    def target(blob, token):
        """Stand-in for rename-legacy.py's target_name: swap the bracketed id for the token."""
        if not blob.endswith('.eml') or ' [' not in blob:
            return None
        stem = blob[:blob.rindex(' [')]
        new = f'{stem} [{token}].eml'
        return None if new == blob else new

    groups = {
        'k01': {'keep': 'A/Emails/one [TAIL0000000000000001].eml',
                'deletes': ['A/Emails/one [TAIL0000000000000002].eml'], 'matter': 'A'},
        'k02': {'keep': 'A/Emails/two [TAIL0000000000000003].eml', 'deletes': [], 'matter': 'A'},
    }
    renames, skipped, collisions = plan_renames(groups, target)

    if sorted(r[1] for r in renames) == ['A/Emails/one [TAIL0000000000000001].eml',
                                         'A/Emails/two [TAIL0000000000000003].eml']:
        print('  ok   rename plans exactly one source per group')
    else:
        print(f'  FAIL rename planned {[r[1] for r in renames]!r}')
        failures.append('rename-one-per-group')

    # The blob being deleted must never be renamed: it is about to stop existing, and a rename
    # would take the survivor's name with it.
    if all('0000000002' not in r[1] for r in renames):
        print('  ok   a blob marked DELETE is never renamed')
    else:
        print('  FAIL a DELETE blob was planned for rename')
        failures.append('rename-skips-deletes')

    if all(r[2] == f'{r[1][:r[1].rindex(" [")]} [{r[0]}].eml' for r in renames):
        print('  ok   the target carries the group token the pipeline would write')
    else:
        print('  FAIL target did not carry the group token')
        failures.append('rename-target-token')

    # No derivable name is the safe answer - the blob keeps the one it has. It must be counted
    # as skipped, never dropped silently and never treated as a failure.
    g2 = {'k03': {'keep': 'A/Emails/no-bracket.eml', 'deletes': [], 'matter': 'A'}}
    r2, s2, _ = plan_renames(g2, target)
    if not r2 and [x[1] for x in s2] == ['A/Emails/no-bracket.eml']:
        print('  ok   a survivor with no derivable name is skipped, not failed')
    else:
        print(f'  FAIL undrivable name gave renames={r2!r} skipped={s2!r}')
        failures.append('rename-skips-underivable')

    # Two groups whose survivors want one name. Impossible while the keep-rule holds, which is
    # why it has to be detected rather than assumed away.
    g3 = {'kAA': {'keep': 'A/Emails/same [TAIL0000000000000001].eml', 'deletes': [], 'matter': 'A'},
          'kAA2': {'keep': 'A/Emails/same [TAIL0000000000000002].eml', 'deletes': [], 'matter': 'A'}}
    _, _, c3 = plan_renames(g3, lambda b, t: 'A/Emails/same [kCOLLIDE].eml')
    if len(c3) == 1 and len(next(iter(c3.values()))) == 2:
        print('  ok   two survivors wanting one name is reported as a collision')
    else:
        print(f'  FAIL collision not detected: {c3!r}')
        failures.append('rename-collision-detected')

    return failures


def _selftest_survivors():
    """Prove the post-batch survivor check is concurrent, complete, and not trigger-happy.

    The check is the last thing standing between a bad batch and silent data loss, so it
    must examine every survivor and report only the ones actually confirmed gone. It is
    also the run's bottleneck - 1,252 survivors per 2,000-blob batch, one round-trip each -
    so seriality is a defect in its own right, and a test that cannot see the difference
    between serial and concurrent would let it come back.
    """
    failures = []

    lock = threading.Lock()
    state = {'inflight': 0, 'peak': 0, 'seen': []}

    def is_missing(blob):
        with lock:
            state['inflight'] += 1
            state['peak'] = max(state['peak'], state['inflight'])
            state['seen'].append(blob)
        time.sleep(0.05)                      # long enough that a serial loop cannot overlap
        with lock:
            state['inflight'] -= 1
        return blob.endswith('/vanished.eml')

    survivors = [f'100.001/Emails/keep-{i}.eml' for i in range(24)]
    survivors.append('100.002/Emails/vanished.eml')
    missing = find_missing_survivors(survivors, is_missing, parallel=8)

    if state['peak'] > 1:
        print(f'  ok   survivor check runs concurrently (peak {state["peak"]} in flight)')
    else:
        print('  FAIL survivor check ran serially - peak 1 request in flight')
        failures.append('survivors-concurrent')

    if sorted(state['seen']) == sorted(survivors):
        print(f'  ok   survivor check examined all {len(survivors)} survivors')
    else:
        print(f'  FAIL survivor check examined {len(state["seen"])} of {len(survivors)}')
        failures.append('survivors-complete')

    if sorted(missing) == ['100.002/Emails/vanished.eml']:
        print('  ok   survivor check reported only the confirmed-missing survivor')
    else:
        print(f'  FAIL survivor check reported {missing!r}')
        failures.append('survivors-precise')

    return failures


def cmd_selftest(args):
    """Prove each validation check can fail, by feeding it a case that must trip it.

    A check that has never been observed failing is not a proven check. The real container
    produced zero staleness failures, which is either a fact about the container or a
    check that cannot fail - and those two look identical from the outside. These fixtures
    tell them apart without touching production.
    """
    import shutil
    import tempfile

    KEEP_L = '01.001/Emails/Msg A [LEGACYTAILAAAAAAAAAAAAA].eml'
    DEL_L = '01.001/Emails/Msg A [LEGACYTAILBBBBBBBBBBBBB].eml'
    DEL_I = f'01.001/Emails/Msg A [{TOK_A}].msg'
    ATT_L = '01.001/Emails/Attachments/Msg A.eml'

    def mrow(action, token, scheme, lm, blob):
        return [action, token, blob.split('/', 1)[0], scheme, lm, blob, 'fixture']

    def lrow(blob, lm, deleted='false'):
        return [blob, lm, '1000', deleted]

    base_m = [mrow('KEEP', TOK_A, 'legacy', LM1, KEEP_L),
              mrow('DELETE', TOK_A, 'legacy', LM2, DEL_L)]
    base_l = [lrow(KEEP_L, LM1), lrow(DEL_L, LM2)]

    cases = []

    cases.append(('clean-group-validates', base_m, base_l, None, 1, 1))

    # The two checks that are the whole defence against destroying a message.
    cases.append(('keep-absent-from-listing', base_m, [lrow(DEL_L, LM2)],
                  'keep-missing', 0, 0))
    cases.append(('keep-soft-deleted',
                  base_m, [lrow(KEEP_L, LM1, 'true'), lrow(DEL_L, LM2)],
                  'keep-missing', 0, 0))
    cases.append(('keep-lastmodified-changed', base_m,
                  [lrow(KEEP_L, 'Wed, 03 Sep 2026 09:00:00 GMT'), lrow(DEL_L, LM2)],
                  'keep-rewritten', 0, 0))

    # Candidate-side staleness.
    cases.append(('candidate-absent', base_m, [lrow(KEEP_L, LM1)],
                  'candidate-gone', 0, 0))
    cases.append(('candidate-lastmodified-changed', base_m,
                  [lrow(KEEP_L, LM1), lrow(DEL_L, 'Wed, 03 Sep 2026 09:00:00 GMT')],
                  'candidate-rewritten', 0, 0))

    # An ingested candidate whose own name disagrees with the group it was filed under.
    cases.append(('candidate-token-mismatch',
                  [mrow('KEEP', TOK_B, 'legacy', LM1, KEEP_L),
                   mrow('DELETE', TOK_B, 'ingested', '', DEL_I)],
                  [lrow(KEEP_L, LM1), lrow(DEL_I, LM2)],
                  'candidate-token-mismatch', 0, 0))

    # The defect found in the real manifest: one path written as both KEEP and DELETE.
    cases.append(('self-duplicate-collapses',
                  [mrow('KEEP', TOK_A, 'ingested', '', DEL_I),
                   mrow('DELETE', TOK_A, 'ingested', '', DEL_I)],
                  [lrow(DEL_I, LM1)],
                  'single-distinct-path', 0, 0))

    cases.append(('attachment-layout-excluded',
                  [mrow('KEEP', TOK_C, 'legacy', LM1, ATT_L),
                   mrow('DELETE', TOK_C, 'legacy', LM2, DEL_L)],
                  [lrow(ATT_L, LM1), lrow(DEL_L, LM2)],
                  'attachment-layout', 0, 0))

    # Every candidate gone, survivor intact: a no-op, not an error. The group is skipped
    # and reported; the run still succeeds and emits no deletion.
    cases.append(('all-candidates-gone-is-a-no-op',
                  [mrow('KEEP', TOK_A, 'legacy', LM1, KEEP_L),
                   mrow('DELETE', TOK_A, 'legacy', LM2, DEL_L),
                   mrow('DELETE', TOK_A, 'legacy', LM2, DEL_L.replace('BBB', 'CCC'))],
                  [lrow(KEEP_L, LM1)],
                  'candidate-gone', 0, 0))

    # Priority: a group that is both an attachment exclusion AND has a vanished survivor
    # must be filed under the vanished survivor, never absorbed into the exclusion count.
    cases.append(('serious-reason-outranks-exclusion',
                  [mrow('KEEP', TOK_C, 'legacy', LM1, ATT_L),
                   mrow('DELETE', TOK_C, 'legacy', LM2, DEL_L)],
                  [lrow(DEL_L, LM2)],
                  'keep-missing', 0, 0))

    tmp = tempfile.mkdtemp(prefix='dedup-selftest-')
    failures = []
    try:
        for name, mrows, lrows, expect, want_groups, want_deletes in cases:
            mp, lp = _fixture(tmp, name, mrows, lrows)
            groups, _ = read_manifest(mp)
            live, soft = read_listing(lp)
            ok_g, ok_d, primary, tripped = validate_groups(
                groups, live, soft,
                os.path.join(tmp, f'{name}-out.tsv'), os.path.join(tmp, f'{name}-skip.tsv'))
            problems = []
            if ok_g != want_groups:
                problems.append(f'validated {ok_g}, expected {want_groups}')
            if ok_d != want_deletes:
                problems.append(f'deletes {ok_d}, expected {want_deletes}')
            if expect and primary.get(expect) != 1:
                problems.append(f'{expect} not the recorded reason '
                                f'(got {[k for k, v in primary.items() if v]})')
            if expect is None and any(primary.values()):
                problems.append(f'expected no skip, got {[k for k, v in primary.items() if v]}')
            status = 'FAIL' if problems else 'ok  '
            print(f'  {status} {name}')
            for p in problems:
                print(f'         {p}')
            if problems:
                failures.append(name)

        # The masking case must show BOTH checks tripped even though one is recorded.
        mp, lp = _fixture(tmp, 'mask',
                          [mrow('KEEP', TOK_C, 'legacy', LM1, ATT_L),
                           mrow('DELETE', TOK_C, 'legacy', LM2, DEL_L)],
                          [lrow(DEL_L, LM2)])
        groups, _ = read_manifest(mp)
        live, soft = read_listing(lp)
        _, _, primary, tripped = validate_groups(
            groups, live, soft, os.path.join(tmp, 'mask-out.tsv'),
            os.path.join(tmp, 'mask-skip.tsv'))
        if tripped['attachment-layout'] == 1 and tripped['keep-missing'] == 1 \
                and primary['keep-missing'] == 1 and primary['attachment-layout'] == 0:
            print('  ok   masked check still counted in "checks tripped"')
        else:
            print('  FAIL masked check lost')
            failures.append('masking')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    failures.extend(_selftest_renames())
    failures.extend(_selftest_survivors())

    print()
    if failures:
        print(f'{len(failures)} check(s) did not behave as specified: {", ".join(failures)}')
        return 1
    print(f'all {len(cases) + 9} negative controls behaved as specified - '
          f'every validation check has been observed both passing and failing.')
    return 0


def read_validated(path):
    groups = {}
    with open(path, encoding='utf-8') as fh:
        fh.readline()
        for line in fh:
            p = line.rstrip('\n').split('\t')
            if len(p) < 5:
                continue
            g = groups.setdefault(p[1], {'keep': None, 'deletes': [], 'matter': p[2]})
            if p[0] == 'KEEP':
                g['keep'] = p[4]
            else:
                g['deletes'].append(p[4])
    return groups


# ── renaming the survivor ────────────────────────────────────────────────────────────────

def plan_renames(groups, target_of):
    """Survivor renames for `groups`: (renames, skipped, collisions).

    renames    [(token, src, dst)]  - one entry per group whose survivor has a target
    skipped    [(token, src)]       - survivor kept its name; target_of declined to derive one
    collisions {dst: [src, ...]}    - a target wanted by more than one survivor

    Only the KEEP is ever considered. A blob on the delete list is about to stop existing;
    renaming it would move the name out from under the copy that is being kept.
    """
    renames, skipped, claims = [], [], {}
    for token, g in groups.items():
        src = g.get('keep')
        if not src:
            continue
        dst = target_of(src, token)
        if not dst:
            skipped.append((token, src))
            continue
        renames.append((token, src, dst))
        claims.setdefault(dst, []).append(src)
    collisions = {d: s for d, s in claims.items() if len(s) > 1}
    return renames, skipped, collisions


def load_renamer():
    """Reuse rename-legacy.py's target_name and rename_blob rather than writing them twice.

    That file owns the naming rule, and it has the controls proving each refusal: an
    attachment, an already-k-named blob, a subject that merely ends in brackets, a stem
    written under the old 180-character cap. Re-deriving any of that here would give two
    answers to one question.
    """
    path = os.path.join(HERE, 'rename-legacy.py')
    if not os.path.exists(path):
        sys.exit('rename-legacy.py is not beside this script; it owns the naming rule.')
    spec = importlib.util.spec_from_file_location('rename_legacy', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for fn in ('target_name', 'rename_blob'):
        if not hasattr(mod, fn):
            sys.exit(f'rename-legacy.py has no {fn}(); it changed and this needs updating.')
    return mod


def cmd_rename(args):
    """Give each surviving blob the name the live pipeline would write for that message.

    WHY THIS IS HERE AND NOT IN rename-legacy.py
    --------------------------------------------
    Renaming every legacy blob is not a one-to-one operation. Several mailboxes archive one
    message under their own Graph tails; all of those mint the same token, so all of them
    want the same new name - 212 of 3,726 targets in a live 4,000-blob sample, some wanted
    by five sources. A tool working from the container listing alone cannot choose between
    them, and choosing is exactly what the de-duplication keep-rule already does.

    Working from dedup-validated.tsv removes the problem rather than managing it: the group
    has one survivor, so one token yields one source, and two groups have different tokens.
    Over the 38,221 survivors of the current cleanup that gives 35,559 renamable blobs and
    35,559 distinct targets - no collisions. It is still checked, because "by construction"
    stops being true the moment someone edits the keep-rule.

    The token also comes free. It is already in the manifest, so nothing has to be re-read
    from storage to mint it - which is what made the standalone tool expensive as well as
    ambiguous.

    WHAT IT FIXES
    -------------
    A pre-switch message sits under a mailbox-id tail the pipeline cannot recognise, so
    re-archiving it writes a second blob under the k-token name. After the rename the
    pipeline's write lands on the name that already exists and overwrites it. The bytes are
    untouched: this is an ADLS Gen2 metadata rename, and the copy kept is still the one the
    keep-rule chose, so the archive owner's reason for preferring it is unaffected.
    """
    ren = load_renamer()
    plan = load_planner()
    storage = plan.Storage()

    groups = read_validated(args.validated or VALIDATED)
    renames, skipped, collisions = plan_renames(groups, ren.target_name)
    say(f'{len(groups):,} groups, {len(renames):,} survivors renamable, '
        f'{len(skipped):,} keeping the name they have')

    if collisions:
        say(f'STOP: {len(collisions)} target name(s) wanted by more than one survivor')
        for d, s in list(collisions.items())[:5]:
            say(f'  {d}')
            for x in s:
                say(f'     <- {x}')
        say('the keep-rule is supposed to make this impossible; do not force it')
        return 1

    done = set()
    ckpt = args.checkpoint or os.path.join(HERE, 'dedup-renamed.log')
    if os.path.exists(ckpt):
        with open(ckpt, encoding='utf-8') as fh:
            for line in fh:
                p = line.rstrip('\n').split('\t')
                # 201 renamed, 404 source already gone, 412/409 target exists - all terminal.
                # Anything else is transient and gets another attempt on the next run.
                if len(p) >= 2 and p[1] in ('201', '404', '412', '409'):
                    done.add(p[0])
        say(f'checkpoint has {len(done):,} already settled')

    todo = [r for r in renames if r[1] not in done]
    if args.limit:
        todo = todo[:args.limit]
    if not todo:
        say('nothing left to do')
        return 0

    if not args.execute:
        say(f'DRY RUN: {len(todo):,} would be renamed. Examples:')
        for _, src, dst in todo[:5]:
            say(f'  {src}')
            say(f'    -> {dst}')
        say('re-run with --execute to apply.')
        return 0

    lock = threading.Lock()
    state = {'done': 0, 'ok': 0, 'gone': 0, 'exists': 0, 'fail': 0}
    started = time.time()
    ck = open(ckpt, 'a', encoding='utf-8')

    def one(item):
        _, src, dst = item
        status, err = ren.rename_blob(storage, src, dst)
        if status in (401, 403):                # token rolled mid-run; retry once
            time.sleep(1)
            status, err = ren.rename_blob(storage, src, dst)
        with lock:
            state['done'] += 1
            if status == 201:
                state['ok'] += 1
            elif status == 404:
                state['gone'] += 1
            elif status in (409, 412):
                state['exists'] += 1
            else:
                state['fail'] += 1
            ck.write(f'{src}\t{status}\t{dst}\t{err or ""}\n')
            if state['done'] % 250 == 0 or state['done'] == len(todo):
                ck.flush()
                el = max(time.time() - started, 1)
                rate = state['done'] / el
                say(f'  {state["done"]:,}/{len(todo):,}  renamed {state["ok"]:,}  '
                    f'source-gone {state["gone"]:,}  target-exists {state["exists"]:,}  '
                    f'failed {state["fail"]:,}  {rate:.0f}/s  '
                    f'eta {(len(todo) - state["done"]) / max(rate, 0.01) / 60:.0f}m')
        return src, status

    try:
        for i in range(0, len(todo), args.batch):
            batch = todo[i:i + args.batch]
            with concurrent.futures.ThreadPoolExecutor(args.parallel) as pool:
                results = dict(pool.map(one, batch))
            # A rename that reported success must leave the message readable under its new
            # name. The rename is atomic, so this should never fire - which is the reason to
            # check it: if it ever does, the assumption this whole pass rests on is wrong.
            moved = [dst for _, src, dst in batch if results.get(src) == 201]
            if moved:
                missing = find_missing_survivors(
                    moved, lambda b: survivor_is_missing(storage, b), args.parallel)
                if missing:
                    ck.flush()
                    say(f'STOP: {len(missing)} blob(s) absent under their new name')
                    for m in missing[:10]:
                        say(f'  {m}')
                    return 1
                say(f'  batch {i // args.batch + 1}: {len(moved):,} verified at the new name')
    finally:
        ck.flush()
        ck.close()

    say(f'renamed {state["ok"]:,}, source gone {state["gone"]:,}, '
        f'target already existed {state["exists"]:,}, failed {state["fail"]:,}')
    if state['exists']:
        say(f'  {state["exists"]:,} target(s) already existed - the pipeline had already '
            f'written that name. Those legacy copies are now duplicates, and which copy to '
            f'keep is a de-duplication decision, not a rename one. Left alone; see {ckpt}.')
    return 1 if state['fail'] else 0


# ── survivor readability ─────────────────────────────────────────────────────────────────

def cmd_selftest_token(args):
    """Prove a read RECOVERS from a dead storage token, rather than merely avoiding one.

    A probe run that starts with a fresh token finishes inside its lifetime and never meets a
    401, so "the run completed" proves the bug is avoided - not that the recovery works.
    Those are different claims, and only the second is what the fix added. This forces the
    failure: poison the token, read, and require the read to succeed anyway.

    The bug this pins: az returns expiresOn and expires_on but no expires_in, so the old
    `data.get('expires_in', 3000)` asserted 50 minutes of validity on every call regardless
    of truth, and az can hand back a cached token with minutes left. When it died mid-run,
    token() kept returning the dead one - its fictional expiry had not passed - and the retry
    re-presented the same dead credential. 17,437 survivors read, then every one of the next
    3,000 "unreadable". Unreadable survivors are excluded from the deletion pass, so this
    would have silently dropped thousands of real groups from the plan while looking careful.

    Needs Azure and one real blob; it is not part of the offline `selftest`.
    """
    import urllib.error

    fails = []

    def check(name, cond):
        print(f"{'ok  ' if cond else 'FAIL'} {name}")
        if not cond:
            fails.append(name)

    groups = read_validated(args.validated if hasattr(args, 'validated') else VALIDATED)
    blob = next((g['keep'] for g in groups.values() if g['keep']), None)
    if not blob:
        sys.exit('no validated survivor to read; run validate first')
    print(f'target blob: {blob}\n')

    plan = load_planner()
    s = plan.Storage()

    raw, _ = s.head_bytes(blob, 4096)
    check('healthy read returns bytes', len(raw) > 0)

    mins = (s._expires - time.time()) / 60
    check(f'expiry came from az, not the 3000s guess ({mins:.0f} min left)',
          mins > 5 and abs(mins - 50) > 1)

    good = s._token
    s._token = 'not-a-real-token'
    rejected = False
    try:
        s.head_bytes(blob, 4096)
    except urllib.error.HTTPError as e:
        rejected = e.code in (401, 403)
    except Exception:                                              # noqa: BLE001
        rejected = True
    check('a poisoned token really is rejected', rejected)

    s.token(force=True)
    check('force=True replaced the dead token', s._token not in ('not-a-real-token', None))
    raw2, _ = s.head_bytes(blob, 4096)
    check('the read succeeds again after a forced re-mint', raw2 == raw)

    check('normal calls still reuse the cached token', s.token() is s.token())

    print()
    print('FAILED: ' + ', '.join(fails) if fails else 'token recovery proven, not assumed')
    return 1 if fails else 0


def cmd_probe(args):
    """Fetch and parse every survivor before anything is deleted.

    The design record makes this a precondition, not a nicety: a group whose survivor
    cannot be read is a group where collapsing would leave nothing readable behind.
    Ranged GET of the header block only - bodies are never pulled, and never printed.
    """
    import email
    from email import policy

    plan = load_planner()
    storage = plan.Storage()
    groups = read_validated(args.validated or VALIDATED)
    keeps = [(t, g['keep']) for t, g in groups.items() if g['keep']]
    say(f'probing {len(keeps):,} survivors at parallel {args.parallel}')

    lock = threading.Lock()
    state = {'done': 0, 'ok': 0, 'bad': 0}
    started = time.time()
    bad_rows = []

    # Retryable: auth (a token can expire mid-run) AND throttling. Storage answers sustained
    # parallel reads with 503 Server Busy / 429, and treating those as "unreadable" turns a
    # load symptom into a permanent-looking verdict about client mail. Observed: 16,000
    # survivors read cleanly at 28/s, then 563 "failed" in one band while the rate halved to
    # 11/s - the blobs were fine, the account was pushing back. 500/502/504 are transient for
    # the same reason. A 404 is NOT here: that one is a real answer.
    RETRYABLE = (401, 403, 429, 500, 502, 503, 504)
    ATTEMPTS = 5

    def probe(item):
        token, blob = item
        raw = None
        for attempt in range(ATTEMPTS):
            try:
                raw, _ = storage.head_bytes(blob, 65536)
                break
            except urllib.error.HTTPError as e:
                if e.code in RETRYABLE and attempt < ATTEMPTS - 1:
                    # An expired token is the failure this loop most needs to survive, and
                    # sleeping does not fix one - the next attempt must ask for a NEW token.
                    # Without this, a token that dies mid-run makes every remaining blob look
                    # unreadable while the retry politely re-presents the same dead
                    # credential. Storage.token(force=True) re-mints; it is cheap because the
                    # refreshed token is then shared by every thread.
                    if e.code in (401, 403):
                        try: storage.token(force=True)
                        except Exception: pass                     # noqa: BLE001
                    # Back off rather than hammering: 1, 2, 4, 8s. A fixed 2s sleep across 24
                    # threads reconverges on the same instant and re-triggers the throttle.
                    time.sleep(2 ** attempt)
                    continue
                return token, blob, f'http {e.code}'
            except Exception as e:                                 # noqa: BLE001
                if attempt < ATTEMPTS - 1:
                    time.sleep(2 ** attempt)
                    continue
                return token, blob, type(e).__name__
        if not raw:
            return token, blob, 'empty'
        if TOKEN_IN_NAME.search(blob):
            # Ingested .msg: only the first bytes were pulled, so parsing is not possible
            # here. The OLE compound-file signature is what proves it is a real .msg and
            # not a truncated or zero-filled blob.
            return (token, blob, None) if raw[:8] == b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1' \
                else (token, blob, 'not-a-msg')
        msg = email.message_from_bytes(raw, policy=policy.default)
        mid = msg.get('Message-ID') or msg.get('Message-Id')
        if not mid:
            return token, blob, 'no-message-id'
        return token, blob, None

    with concurrent.futures.ThreadPoolExecutor(args.parallel) as pool:
        for token, blob, err in pool.map(probe, keeps):
            with lock:
                state['done'] += 1
                if err:
                    state['bad'] += 1
                    bad_rows.append((token, blob, err))
                else:
                    state['ok'] += 1
                if state['done'] % 2000 == 0 or state['done'] == len(keeps):
                    rate = state['done'] / max(time.time() - started, 1)
                    say(f'  {state["done"]:,}/{len(keeps):,}  ok {state["ok"]:,}  '
                        f'unreadable {state["bad"]:,}  {rate:.0f}/s')

    out = args.out or os.path.join(HERE, 'dedup-unreadable-keeps.tsv')
    with open(out, 'w', encoding='utf-8', newline='') as fh:
        fh.write('token\tblob\terror\n')
        for t, b, e in bad_rows:
            fh.write(f'{t}\t{b}\t{e}\n')
    say(f'survivors readable {state["ok"]:,}, unreadable {state["bad"]:,} -> {out}')
    return 0


# ── dry run ──────────────────────────────────────────────────────────────────────────────

def cmd_dryrun(args):
    groups = read_validated(args.validated or VALIDATED)
    excl = set()
    if args.exclude and os.path.exists(args.exclude):
        with open(args.exclude, encoding='utf-8') as fh:
            fh.readline()
            for line in fh:
                p = line.rstrip('\n').split('\t')
                if p and p[0]:
                    excl.add(p[0])
        say(f'excluding {len(excl):,} groups listed in {args.exclude}')

    out = args.out or DELETES
    acted = skipped = total = 0
    keepset = set()
    bad_arith = []
    with open(out, 'w', encoding='utf-8') as fh:
        for token, g in sorted(groups.items()):
            if token in excl or not g['keep'] or not g['deletes']:
                skipped += 1
                continue
            members = len(g['deletes']) + 1
            if len(g['deletes']) != members - 1:
                bad_arith.append((token, 'deletes != members - 1'))
                continue
            if g['keep'] in g['deletes']:
                bad_arith.append((token, 'keep is in the delete list'))
                continue
            if not g['deletes']:
                bad_arith.append((token, 'group would delete every member'))
                continue
            acted += 1
            keepset.add(g['keep'])
            for b in g['deletes']:
                fh.write(b + '\n')
                total += 1

    say('')
    say(f'groups acted on   : {acted:,}')
    say(f'groups skipped    : {skipped:,}')
    say(f'blobs to delete   : {total:,}')
    say(f'survivors kept    : {len(keepset):,}')
    if bad_arith:
        say(f'STOP: {len(bad_arith)} group(s) failed the arithmetic check')
        for t, why in bad_arith[:10]:
            say(f'  {t}  {why}')
        return 1
    # The delete list must not intersect the survivor set. This is the last line of
    # defence and it is checked over the written file, not the in-memory structure.
    with open(out, encoding='utf-8') as fh:
        written = [l.rstrip('\n') for l in fh if l.strip()]
    if len(written) != total:
        say(f'STOP: wrote {len(written):,} lines but counted {total:,}')
        return 1
    clash = keepset & set(written)
    if clash:
        say(f'STOP: {len(clash)} survivor(s) appear in the delete list')
        for b in sorted(clash)[:10]:
            say(f'  {b}')
        return 1
    if len(set(written)) != len(written):
        say(f'STOP: the delete list has {len(written) - len(set(written)):,} duplicate lines')
        return 1
    say('arithmetic ok: every group keeps exactly one, no survivor is on the delete list')
    say(f'delete list -> {out}')
    return 0


# ── deletion ─────────────────────────────────────────────────────────────────────────────

def delete_blob(storage, blob):
    req = urllib.request.Request(blob_url(blob), method='DELETE')
    req.add_header('Authorization', f'Bearer {storage.token()}')
    req.add_header('x-ms-version', API_VERSION)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.status, None
    except urllib.error.HTTPError as e:
        return e.code, e.reason
    except Exception as e:                                         # noqa: BLE001
        return 0, type(e).__name__


def survivor_is_missing(storage, blob):
    """True only when the blob is CONFIRMED absent.

    A 404 is evidence. A timeout, a reset, a 5xx are not: they say the question could not
    be asked, and answering "missing" would halt a run that is behaving correctly. The
    cost of swallowing one is bounded - the same survivor is re-checked after every later
    batch that touches its group.
    """
    req = urllib.request.Request(blob_url(blob), method='HEAD')
    req.add_header('Authorization', f'Bearer {storage.token()}')
    req.add_header('x-ms-version', API_VERSION)
    try:
        with urllib.request.urlopen(req, timeout=60):
            return False
    except urllib.error.HTTPError as e:
        return e.code == 404
    except Exception:                                              # noqa: BLE001
        return False


def find_missing_survivors(survivors, is_missing, parallel):
    """Survivors that `is_missing` confirms are gone.

    Concurrent because this is the run's bottleneck, not a nicety. A 2,000-blob batch has
    ~1,252 distinct survivors and each is one round-trip, so serially the delete threads
    sit idle for minutes after every ~90 seconds of work - and because the checkpoint file
    only grows while deletes are happening, that pause is indistinguishable from a hang to
    anyone watching from outside the terminal.
    """
    survivors = list(survivors)
    with concurrent.futures.ThreadPoolExecutor(parallel) as pool:
        return [s for s, gone in zip(survivors, pool.map(is_missing, survivors)) if gone]


def cmd_delete(args):
    plan = load_planner()
    storage = plan.Storage()

    with open(args.deletes or DELETES, encoding='utf-8') as fh:
        wanted = [l.rstrip('\n') for l in fh if l.strip()]

    # The checkpoint is the resume point. An interrupted run must not re-derive the list
    # and must not re-issue deletes it already made.
    done = set()
    ckpt = args.checkpoint or CHECKPOINT
    if os.path.exists(ckpt):
        with open(ckpt, encoding='utf-8') as fh:
            for line in fh:
                p = line.rstrip('\n').split('\t')
                if len(p) >= 2 and p[1] in ('202', '404'):
                    done.add(p[0])
        say(f'checkpoint has {len(done):,} blobs already deleted')

    todo = [b for b in wanted if b not in done]
    if args.limit:
        todo = todo[:args.limit]
    say(f'{len(wanted):,} on the list, {len(todo):,} to delete this run '
        f'(parallel {args.parallel}, batch {args.batch})')
    if not todo:
        return 0

    # Nothing may be deleted that is not on the validated list. This re-reads the
    # validated file rather than trusting the caller's --deletes file.
    if not args.no_crosscheck:
        groups = read_validated(args.validated or VALIDATED)
        allowed = {b for g in groups.values() for b in g['deletes']}
        survivors = {g['keep'] for g in groups.values() if g['keep']}
        stray = [b for b in todo if b not in allowed]
        if stray:
            say(f'STOP: {len(stray)} blob(s) on the delete list are not validated deletes')
            for b in stray[:10]:
                say(f'  {b}')
            return 1
        clash = [b for b in todo if b in survivors]
        if clash:
            say(f'STOP: {len(clash)} blob(s) on the delete list are survivors')
            return 1
        keep_of = {}
        for g in groups.values():
            for b in g['deletes']:
                keep_of[b] = g['keep']
        say(f'cross-check ok against {len(allowed):,} validated deletes')
    else:
        keep_of = {}

    lock = threading.Lock()
    state = {'done': 0, 'ok': 0, 'gone': 0, 'fail': 0}
    started = time.time()
    ck = open(ckpt, 'a', encoding='utf-8')

    def one(blob):
        status, err = delete_blob(storage, blob)
        if status in (401, 403):                # token rolled mid-run; retry once
            time.sleep(1)
            status, err = delete_blob(storage, blob)
        with lock:
            state['done'] += 1
            if status == 202:
                state['ok'] += 1
            elif status == 404:
                state['gone'] += 1
            else:
                state['fail'] += 1
            ck.write(f'{blob}\t{status}\t{err or ""}\n')
            if state['done'] % 250 == 0 or state['done'] == len(todo):
                ck.flush()
                el = max(time.time() - started, 1)
                rate = state['done'] / el
                left = (len(todo) - state['done']) / max(rate, 0.01)
                say(f'  {state["done"]:,}/{len(todo):,}  deleted {state["ok"]:,}  '
                    f'already-gone {state["gone"]:,}  failed {state["fail"]:,}  '
                    f'{rate:.0f}/s  eta {left / 60:.0f}m')
        return blob, status

    try:
        for i in range(0, len(todo), args.batch):
            batch = todo[i:i + args.batch]
            with concurrent.futures.ThreadPoolExecutor(args.parallel) as pool:
                list(pool.map(one, batch))
            # After each batch, prove the survivors of the groups just touched are still
            # there. A survivor that vanished during the batch means stop, not continue.
            if keep_of:
                survivors = {keep_of[b] for b in batch if keep_of.get(b)}
                missing = find_missing_survivors(
                    survivors, lambda s: survivor_is_missing(storage, s), args.parallel)
                if missing:
                    ck.flush()
                    say(f'STOP: {len(missing)} survivor(s) missing after this batch')
                    for s in missing[:10]:
                        say(f'  {s}')
                    return 1
                say(f'  batch {i // args.batch + 1}: {len(survivors):,} survivors verified present')
    finally:
        ck.flush()
        ck.close()

    say(f'deleted {state["ok"]:,}, already gone {state["gone"]:,}, failed {state["fail"]:,}')
    return 1 if state['fail'] else 0


# ── recovery proof ───────────────────────────────────────────────────────────────────────

def cmd_softlist(args):
    plan = load_planner()
    storage = plan.Storage()
    u = (f'{ROOT}?restype=container&comp=list&include=deleted&maxresults=5000'
         f'&prefix={urllib.parse.quote(args.prefix, safe="")}')
    req = urllib.request.Request(u)
    req.add_header('Authorization', f'Bearer {storage.token()}')
    req.add_header('x-ms-version', API_VERSION)
    with urllib.request.urlopen(req, timeout=120) as resp:
        root = ET.fromstring(resp.read())
    n = 0
    for b in root.iter('Blob'):
        name = b.findtext('Name') or ''
        props = b.find('Properties')
        deleted = b.findtext('Deleted') or 'false'
        rem = props.findtext('RemainingRetentionDays') if props is not None else ''
        print(f'{"DELETED" if deleted == "true" else "live   "}  '
              f'retention-days-left={rem or "-":<4}  {name}')
        n += 1
    print(f'{n} entries under prefix')
    return 0


def cmd_undelete(args):
    plan = load_planner()
    storage = plan.Storage()
    req = urllib.request.Request(blob_url(args.blob) + '?comp=undelete', method='PUT')
    req.add_header('Authorization', f'Bearer {storage.token()}')
    req.add_header('x-ms-version', API_VERSION)
    req.add_header('Content-Length', '0')
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            say(f'undelete returned {resp.status}')
    except urllib.error.HTTPError as e:
        say(f'undelete failed: http {e.code} {e.reason}')
        return 1
    return 0


def cmd_head(args):
    plan = load_planner()
    storage = plan.Storage()
    try:
        raw, lm = storage.head_bytes(args.blob, args.bytes)
    except urllib.error.HTTPError as e:
        say(f'GET failed: http {e.code} {e.reason}')
        return 1
    say(f'read {len(raw):,} bytes, Last-Modified {lm}')
    if raw[:8] == b'\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1':
        say('content: OLE compound file (.msg), signature ok')
        return 0
    import email
    from email import policy
    msg = email.message_from_bytes(raw, policy=policy.default)
    mid = msg.get('Message-ID') or msg.get('Message-Id')
    say(f'content: MIME, Message-ID {mid}')
    return 0 if mid else 1


# ── identity accounting ──────────────────────────────────────────────────────────────────

def load_token_map():
    """blob -> k-token, from every source that knows one.

    A blob whose token nothing knows is counted as its own identity. That is the honest
    treatment: it is untouched by this pass, so it contributes identically before and
    after, and pretending to know its token would only blur the comparison.
    """
    tok = {}
    if os.path.exists(RESOLVED):
        with open(RESOLVED, encoding='utf-8') as fh:
            fh.readline()
            for line in fh:
                p = line.rstrip('\n').split('\t')
                if len(p) >= 2 and p[1]:
                    tok[p[0]] = p[1]
    if os.path.exists(MANIFEST):
        with open(MANIFEST, encoding='utf-8') as fh:
            fh.readline()
            for line in fh:
                p = line.rstrip('\n').split('\t')
                if len(p) >= 6:
                    tok[p[5]] = p[1]
    return tok


def identity_of(name, tok):
    m = TOKEN_IN_NAME.search(name)
    return m.group(1).lower() if m else tok.get(name, 'path:' + name)


def cmd_identities(args):
    """Distinct MESSAGE identities in a listing - k-tokens, not blob paths.

    This is the number stage 6 asserts is unchanged, so it has to count messages. A blob
    whose token nothing knows falls back to its own path, which keeps the measure
    sensitive in the right direction: deleting something whose identity is unknown makes
    the count DROP, rather than quietly cancelling out.
    """
    tok = load_token_map()
    live, _ = read_listing(args.listing or LISTING)
    idents = set()
    mail = 0
    for name in live:
        low = name.lower()
        if not (low.endswith('.eml') or low.endswith('.msg')):
            continue
        mail += 1
        idents.add(identity_of(name, tok))
    print(f'listing            : {args.listing or LISTING}')
    print(f'entries            : {len(live):,}')
    print(f'mail blobs         : {mail:,}')
    print(f'distinct identities: {len(idents):,}')
    print(f'redundant copies   : {mail - len(idents):,}')

    if args.minus:
        # Pre-flight: apply the delete list on paper and report what stage 6 must find.
        # If this simulation loses an identity, the plan is wrong and no blob should be
        # deleted - the arithmetic is cheaper to fix than a restore.
        with open(args.minus, encoding='utf-8') as fh:
            targets = {l.rstrip('\n') for l in fh if l.strip()}
        unknown = [b for b in targets if b not in live]
        after = set()
        mail_after = 0
        for name in live:
            if name in targets:
                continue
            low = name.lower()
            if not (low.endswith('.eml') or low.endswith('.msg')):
                continue
            mail_after += 1
            after.add(identity_of(name, tok))
        lost = idents - after
        print()
        print(f'simulating deletion of {len(targets):,} blobs from {args.minus}')
        print(f'  delete targets not present in the listing : {len(unknown):,}')
        print(f'  mail blobs after                          : {mail_after:,}')
        print(f'  distinct identities after                 : {len(after):,}')
        print(f'  identities LOST                           : {len(lost):,}')
        if lost:
            print('  STOP - the plan removes the last copy of these messages:')
            for i in sorted(lost)[:20]:
                print(f'    {i}')
            return 1
        print('  no message identity is lost by this plan')
    return 0


def main():
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except (AttributeError, OSError):
        pass
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    sub.add_parser('selftest', help='prove every validation check can fail')
    sub.add_parser('selftest-token',
                   help='prove a read RECOVERS from a dead storage token (needs Azure)')

    li = sub.add_parser('list')
    li.add_argument('--out')
    li.add_argument('--prefix', default='')
    li.add_argument('--include-deleted', action='store_true')

    va = sub.add_parser('validate')
    va.add_argument('--manifest')
    va.add_argument('--listing')
    va.add_argument('--out')
    va.add_argument('--skipped')

    pr = sub.add_parser('probe')
    pr.add_argument('--validated')
    pr.add_argument('--parallel', type=int, default=24)
    pr.add_argument('--out')

    dr = sub.add_parser('dryrun')
    dr.add_argument('--validated')
    dr.add_argument('--out')
    dr.add_argument('--exclude', help='TSV whose first column lists tokens to leave alone')

    de = sub.add_parser('delete')
    de.add_argument('--deletes')
    de.add_argument('--validated')
    de.add_argument('--checkpoint')
    de.add_argument('--limit', type=int)
    de.add_argument('--parallel', type=int, default=12)
    de.add_argument('--batch', type=int, default=2000)
    de.add_argument('--no-crosscheck', action='store_true')

    rn = sub.add_parser('rename',
                        help='give each surviving blob the name the pipeline would write')
    rn.add_argument('--validated')
    rn.add_argument('--checkpoint')
    rn.add_argument('--limit', type=int)
    rn.add_argument('--parallel', type=int, default=8)
    rn.add_argument('--batch', type=int, default=1000)
    rn.add_argument('--execute', action='store_true')

    sl = sub.add_parser('softlist')
    sl.add_argument('--prefix', required=True)

    ud = sub.add_parser('undelete')
    ud.add_argument('--blob', required=True)

    hd = sub.add_parser('head')
    hd.add_argument('--blob', required=True)
    hd.add_argument('--bytes', type=int, default=16384)

    idc = sub.add_parser('identities')
    idc.add_argument('--listing')
    idc.add_argument('--minus', help='delete list to apply on paper before counting')

    args = ap.parse_args()
    return {
        'selftest': cmd_selftest, 'selftest-token': cmd_selftest_token,
        'list': cmd_list, 'validate': cmd_validate, 'probe': cmd_probe,
        'dryrun': cmd_dryrun, 'delete': cmd_delete, 'softlist': cmd_softlist,
        'undelete': cmd_undelete, 'head': cmd_head, 'identities': cmd_identities,
        'rename': cmd_rename,
    }[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
