"""Plan - never execute - the removal of duplicate messages from the matters container.

Implements the dry run in docs/superpowers/specs/2026-09-08-duplicate-blob-cleanup-design.md.

    python dedup-plan.py selftest [--sample 40]
    python dedup-plan.py plan [--out dedup-manifest.tsv] [--parallel 24] [--limit N]

THIS SCRIPT DELETES NOTHING. It contains no DELETE call of any kind, and it asks Azure
only for GETs. The manifest it writes is the artefact a person reviews and signs off; the
deletion pass is separate work that does not exist yet. Keep it that way - the moment a
delete lands in here, "run the planner" stops being a safe thing to say.

--- how identity is decided -------------------------------------------------------------

Message-ID alone is NOT identity in this corpus: 3,835 groups of genuinely different
messages share one, because Outlook reuses the header. The key is the same one the ingest
already uses, from ingest-key.py:

    token = 'k' + sha256( lower(message-id) + '|' + sent-date-utc-to-the-second )[:22]

Rather than reimplement that, this imports ingest-key.py directly. A second implementation
that drifted by one character would silently mis-group real client mail, and `selftest`
exists to prove the import really does reproduce the tokens already written into blob
names.

--- why .msg costs nothing to resolve ----------------------------------------------------

The corpus splits perfectly by scheme, which was measured rather than assumed:

    401,170 .msg  - every one ingested, carrying [k<22 hex>] in its own name
    258,974 .eml  - every one written by the Logic App, named by Graph message id

So an ingested blob states its own identity and needs no download. Only the legacy .eml
side needs a ranged GET of its header block. That is the difference between reading a few
hundred MB and pulling tens of GB of .msg bodies across the wire.
"""
import argparse
import base64
import concurrent.futures
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# messageid-index.tsv is a gitignored build artefact, so it sits wherever
# build-messageid-index.ps1 last ran - which is often a different checkout from this one.
INDEX = os.path.join(HERE, 'messageid-index.tsv')
CACHE = os.path.join(HERE, 'dedup-resolved.tsv')
BASE = 'https://samatters.blob.core.windows.net/matters/'
AZ = os.path.expandvars(r'%LOCALAPPDATA%\AzureCLI\bin\az.cmd')

# A dropped x-ms-version once turned 195,815 auth failures into a confident "no
# Message-ID" in build-messageid-index.ps1. Send it on every request.
API_VERSION = '2021-08-06'
HEAD_BYTES = 16384      # first read; 8 KB missed ~8% of headers in that script's testing
RETRY_BYTES = 131072    # second read for blobs whose headers run past HEAD_BYTES

TOKEN_IN_NAME = re.compile(r'\[(k[0-9a-f]{22})\]\.(?:eml|msg)$', re.IGNORECASE)


def load_ingest_key():
    """Import ingest-key.py by path. Its hyphen makes it un-importable by name."""
    path = os.path.join(HERE, 'ingest-key.py')
    if not os.path.exists(path):
        sys.exit('ingest-key.py is not beside this script. It is the authoritative token\n'
                 'implementation and this planner will not guess at a second one.')
    spec = importlib.util.spec_from_file_location('ingest_key', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    for fn in ('dedup_key', 'clean_mid', 'sent_utc', 'describe_msg'):
        if not hasattr(mod, fn):
            sys.exit(f'ingest-key.py has no {fn}(); its interface changed and this planner '
                     f'needs updating rather than working around it.')
    return mod


# ── storage ──────────────────────────────────────────────────────────────────────────────

class Storage:
    """Ranged reads against the container, with a token that refreshes before expiry."""

    def __init__(self):
        self._token = None
        self._expires = 0

    def token(self):
        if self._token and time.time() < self._expires - 300:
            return self._token
        out = subprocess.run(
            [AZ, 'account', 'get-access-token', '--resource', 'https://storage.azure.com/',
             '-o', 'json'],
            capture_output=True, text=True)
        if out.returncode != 0:
            sys.exit(f'could not get a storage token from az:\n{out.stderr.strip()}')
        data = json.loads(out.stdout)
        self._token = data['accessToken']
        # expiresOn is local time without a zone; lean on expires_in when present.
        self._expires = time.time() + int(data.get('expires_in', 3000))
        return self._token

    def url(self, blob_name):
        # Each segment is quoted separately so '/' survives. Non-ASCII names are common
        # here - Spanish party names and en-dashes - and a wrongly encoded one 404s on a
        # blob that is present and readable.
        return BASE + '/'.join(urllib.parse.quote(p, safe='') for p in blob_name.split('/'))

    def head_bytes(self, blob_name, n):
        """First n bytes plus Last-Modified. Returns (bytes, last_modified) or raises."""
        req = urllib.request.Request(self.url(blob_name))
        req.add_header('Authorization', f'Bearer {self.token()}')
        req.add_header('x-ms-version', API_VERSION)
        req.add_header('Range', f'bytes=0-{n - 1}')
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.read(), resp.headers.get('Last-Modified', '')

    def head_bytes_sized(self, blob_name, n):
        """As head_bytes, plus the blob's full size read off Content-Range."""
        req = urllib.request.Request(self.url(blob_name))
        req.add_header('Authorization', f'Bearer {self.token()}')
        req.add_header('x-ms-version', API_VERSION)
        req.add_header('Range', f'bytes=0-{n - 1}')
        with urllib.request.urlopen(req, timeout=120) as resp:
            rng = resp.headers.get('Content-Range', '')        # 'bytes 0-16383/238160'
            total = int(rng.rsplit('/', 1)[1]) if '/' in rng else 0
            return resp.read(), resp.headers.get('Last-Modified', ''), total


# ── identity resolution ──────────────────────────────────────────────────────────────────

def token_from_name(blob_name):
    m = TOKEN_IN_NAME.search(blob_name)
    return m.group(1) if m else None


def resolve_eml(storage, key_mod, blob_name):
    """Read a legacy .eml's header block and derive its token.

    Returns (token, messageId, sentDate, lastModified, error).
    """
    import email
    from email import policy

    for size in (HEAD_BYTES, RETRY_BYTES):
        try:
            raw, last_modified = storage.head_bytes(blob_name, size)
        except urllib.error.HTTPError as e:
            return None, None, None, None, f'http {e.code}'
        except Exception as e:                                   # noqa: BLE001
            return None, None, None, None, f'{type(e).__name__}'

        msg = email.message_from_bytes(raw, policy=policy.default)
        mid = key_mod.clean_mid(msg.get('Message-ID') or msg.get('Message-Id'))
        sent = key_mod.sent_utc(msg)
        if mid and sent:
            return key_mod.dedup_key(mid, sent), mid, sent, last_modified, None
        # Headers may have run past this read; the loop widens once before giving up.

    missing = 'no Message-ID' if not mid else 'no Date'
    return None, mid, sent, last_modified, missing


# ── candidate grouping ───────────────────────────────────────────────────────────────────

def matter_of(blob_name):
    return blob_name.split('/', 1)[0]


def load_candidates(index_path, limit=None):
    """Blobs whose Message-ID is shared, and whose group sits inside one matter folder.

    Cross-matter groups are excluded here rather than later: a message filed under two
    matters may have been put there deliberately, and the folder is the only
    classification a person actually made.
    """
    by_mid = {}
    with open(index_path, encoding='utf-8') as fh:
        header = fh.readline()
        if not header.startswith('blob\t'):
            sys.exit(f'{index_path} does not look like the Message-ID index')
        for line in fh:
            parts = line.rstrip('\n').split('\t')
            if len(parts) < 3 or parts[2] != 'ok' or not parts[1]:
                continue
            # A blob path may appear more than once in the index - paging returns the same
            # message twice, and collision-truth.ps1 carries a warning about exactly this.
            # Appending blindly puts one path in its group twice, and choose_survivor then
            # labels the second copy DELETE: the manifest generated before this fix told
            # the executor to delete the sole copy of 8,819 messages, each row reading
            # "duplicate of <itself>". A blob cannot be a duplicate of itself; a group's
            # membership is its set of distinct paths.
            paths = by_mid.setdefault(parts[1], [])
            if parts[0] not in paths:
                paths.append(parts[0])

    groups, skipped_cross = [], 0
    for mid, blobs in by_mid.items():
        if len(blobs) < 2:
            continue
        if len({matter_of(b) for b in blobs}) > 1:
            skipped_cross += 1
            continue
        groups.append((mid, blobs))
        if limit and len(groups) >= limit:
            break
    return groups, skipped_cross


# ── survivor rule ────────────────────────────────────────────────────────────────────────

def choose_survivor(rows):
    """Which copy stays. rows are dicts with blob/scheme/lastModified.

    Legacy first: the ingest re-serialises MIME rather than copying it (238,160 bytes in,
    234,001 out on the sample INGEST-BLOB-NAMING.md measured), so the Logic App's blob is
    closer to what actually arrived. Then oldest, then name, so the choice is deterministic
    and a re-run picks the same survivor.
    """
    return sorted(rows, key=lambda r: (r['scheme'] != 'legacy',
                                       r['lastModified'] or '',
                                       r['blob']))[0]


# ── commands ─────────────────────────────────────────────────────────────────────────────

def cmd_selftest_grouping(args):
    """A repeated row in the index must never become an order to delete the only copy.

    Regression test for the worst defect this tool has had. messageid-index.tsv can list one
    blob path twice under a message id (paging returns the same message twice - the same trap
    collision-truth.ps1 warns about). load_candidates appended blindly, so the path joined its
    group twice, and the KEEP/DELETE loop compared rows with `r is survivor` - object
    identity. Two dicts for one path are not the same object, so the survivor's own path was
    emitted as DELETE, reason "duplicate of <itself>".

    That reached a signed-off manifest: 8,819 of 47,121 groups, every one of them an
    instruction to delete the sole copy of a message. It was caught by the executor
    re-reading the container, not by anything here.

    Offline and fast - no network, no storage account, no index file. Run it after touching
    load_candidates or choose_survivor.
    """
    import tempfile

    fails = []

    def check(name, cond):
        print(f"{'ok  ' if cond else 'FAIL'} {name}")
        if not cond:
            fails.append(name)

    idx = os.path.join(tempfile.mkdtemp(), 'messageid-index.tsv')
    with open(idx, 'w', encoding='utf-8') as fh:
        fh.write('blob\tmessageId\tstatus\n')
        # a real duplicate pair, but with the first path listed twice
        fh.write('matters/01.001/Emails/a [AAA].eml\t<m1@x>\tok\n')
        fh.write('matters/01.001/Emails/a [AAA].eml\t<m1@x>\tok\n')
        fh.write('matters/01.001/Emails/b [BBB].eml\t<m1@x>\tok\n')
        # a "group" that is one path twice: not a duplicate group at all
        fh.write('matters/01.001/Emails/c [CCC].eml\t<m2@x>\tok\n')
        fh.write('matters/01.001/Emails/c [CCC].eml\t<m2@x>\tok\n')

    by_mid = dict(load_candidates(idx)[0])
    check('a repeated path collapses to one group member',
          by_mid.get('<m1@x>') == ['matters/01.001/Emails/a [AAA].eml',
                                   'matters/01.001/Emails/b [BBB].eml'])
    check('one path listed twice is not a duplicate group',
          '<m2@x>' not in by_mid)

    # Two distinct dicts for one blob - what the old comparison could not tell apart.
    rows = [
        {'blob': 'matters/01.001/Emails/a [AAA].eml', 'scheme': 'legacy', 'lastModified': '2026-01-01T00:00:00Z'},
        {'blob': 'matters/01.001/Emails/a [AAA].eml', 'scheme': 'legacy', 'lastModified': '2026-01-01T00:00:00Z'},
        {'blob': 'matters/01.001/Emails/b [BBB].eml', 'scheme': 'ktoken', 'lastModified': '2026-02-01T00:00:00Z'},
    ]
    survivor = choose_survivor(rows)
    check('every row naming the survivor path is KEEP',
          [r['blob'] == survivor['blob'] for r in rows] == [True, True, False])
    # The control: without it, the two checks above could pass against code that never had
    # the bug, and this test would prove nothing about the fix.
    check('control - the old `is` comparison does mislabel one of them',
          [r is survivor for r in rows] == [True, False, False])
    check('survivor is the legacy copy, per the signed-off keep-rule',
          survivor['blob'].endswith('a [AAA].eml'))

    print()
    print('FAILED: ' + ', '.join(fails) if fails else 'grouping selftest passed')
    return 1 if fails else 0


def cmd_selftest(args):
    """Prove the imported token function reproduces tokens already in blob names.

    Downloads whole .msg blobs, which is why this runs over a sample rather than the
    corpus. If this fails, every grouping decision the planner makes is suspect.
    """
    key_mod = load_ingest_key()
    storage = Storage()

    named = []
    with open(args.index, encoding='utf-8') as fh:
        fh.readline()
        for line in fh:
            blob = line.split('\t', 1)[0]
            if token_from_name(blob):
                named.append(blob)
            if len(named) >= args.sample * 4:
                break
    sample = named[::4][:args.sample]
    print(f'checking {len(sample)} ingested blobs\n')

    import tempfile
    ok = bad = failed = 0
    for i, blob in enumerate(sample, 1):
        expected = token_from_name(blob)
        try:
            raw, _ = storage.head_bytes(blob, 40 * 1024 * 1024)
        except Exception as e:                                    # noqa: BLE001
            failed += 1
            print(f'  [{i}/{len(sample)}] fetch failed ({type(e).__name__})')
            continue
        with tempfile.NamedTemporaryFile(suffix='.msg', delete=False) as tf:
            tf.write(raw)
            tmp = tf.name
        try:
            got = key_mod.describe_msg(tmp)['token']
        except Exception as e:                                    # noqa: BLE001
            failed += 1
            print(f'  [{i}/{len(sample)}] parse failed ({type(e).__name__})')
            continue
        finally:
            os.unlink(tmp)
        if got == expected:
            ok += 1
        else:
            bad += 1
            print(f'  [{i}/{len(sample)}] MISMATCH name={expected} recomputed={got}')

    print(f'\nmatched {ok}, mismatched {bad}, unreadable {failed}')
    if bad:
        print('\nThe token function does not reproduce what named these blobs.\n'
              'Do not trust any manifest until this is understood.')
        return 1
    if not ok:
        print('\nNothing verified. Treat the planner as unproven.')
        return 1
    print('\nIdentity function agrees with the names already in the container.')
    return 0


def cmd_plan(args):
    key_mod = load_ingest_key()
    storage = Storage()

    print('loading candidates from the Message-ID index ...')
    groups, skipped_cross = load_candidates(args.index, args.limit)
    blobs = [b for _, bs in groups for b in bs]
    legacy = [b for b in blobs if not token_from_name(b)]
    print(f'  candidate groups (same matter) : {len(groups):,}')
    print(f'  cross-matter groups excluded   : {skipped_cross:,}')
    print(f'  blobs to consider              : {len(blobs):,}')
    print(f'  legacy .eml needing a read     : {len(legacy):,}\n')

    resolved = {}
    if os.path.exists(CACHE):
        with open(CACHE, encoding='utf-8') as fh:
            fh.readline()
            for line in fh:
                p = line.rstrip('\n').split('\t')
                if len(p) >= 5:
                    resolved[p[0]] = {'token': p[1] or None, 'messageId': p[2],
                                      'sent': p[3], 'lastModified': p[4],
                                      'error': p[5] if len(p) > 5 else ''}
        print(f'resumed {len(resolved):,} already-resolved blobs from cache\n')

    # A cached failure is retried. Most are URLError - a transient network blip, not a
    # property of the blob - and leaving them cached would quietly turn a 2% hiccup into a
    # permanent hole in the manifest, with the affected groups skipped every future run.
    # A later row for the same blob overwrites the earlier one on load, so the retry wins.
    todo = [b for b in legacy if b not in resolved or resolved[b].get('error')]
    if todo:
        print(f'reading {len(todo):,} header blocks at parallel {args.parallel} ...')
        done = 0
        started = time.time()
        with open(CACHE, 'a', encoding='utf-8') as cache_fh:
            if os.path.getsize(CACHE) == 0 if os.path.exists(CACHE) else True:
                cache_fh.write('blob\ttoken\tmessageId\tsent\tlastModified\terror\n')
            with concurrent.futures.ThreadPoolExecutor(args.parallel) as pool:
                futures = {pool.submit(resolve_eml, storage, key_mod, b): b for b in todo}
                for fut in concurrent.futures.as_completed(futures):
                    blob = futures[fut]
                    token, mid, sent, lm, err = fut.result()
                    resolved[blob] = {'token': token, 'messageId': mid or '',
                                      'sent': sent or '', 'lastModified': lm or '',
                                      'error': err or ''}
                    cache_fh.write(f'{blob}\t{token or ""}\t{mid or ""}\t{sent or ""}\t'
                                   f'{lm or ""}\t{err or ""}\n')
                    done += 1
                    if done % 500 == 0 or done == len(todo):
                        rate = done / max(time.time() - started, 1)
                        cache_fh.flush()
                        print(f'  {done:,}/{len(todo):,}  {rate:.0f}/s', flush=True)
        print()

    # Regroup on the real key. A Message-ID group can split into several tokens - that is
    # the 3,835-collision case doing its job - or collapse to one.
    by_token = {}
    unresolved_groups = 0
    for mid, group_blobs in groups:
        rows, bad = [], False
        for blob in group_blobs:
            name_token = token_from_name(blob)
            if name_token:
                rows.append({'blob': blob, 'token': name_token, 'scheme': 'ingested',
                             'lastModified': '', 'messageId': mid})
            else:
                r = resolved.get(blob)
                if not r or not r['token']:
                    bad = True
                    break
                rows.append({'blob': blob, 'token': r['token'], 'scheme': 'legacy',
                             'lastModified': r['lastModified'], 'messageId': mid})
        if bad:
            unresolved_groups += 1
            continue
        for r in rows:
            by_token.setdefault(r['token'], []).append(r)

    out = args.out or os.path.join(HERE, 'dedup-manifest.tsv')
    kept = deleted = real_groups = 0
    with open(out, 'w', encoding='utf-8', newline='') as fh:
        fh.write('action\ttoken\tmatter\tscheme\tlastModified\tblob\treason\n')
        for token, rows in sorted(by_token.items()):
            if len(rows) < 2:
                continue
            if len({matter_of(r['blob']) for r in rows}) > 1:
                continue   # split back across matters once regrouped; leave alone
            real_groups += 1
            survivor = choose_survivor(rows)
            for r in rows:
                # By PATH, not by object identity. `r is survivor` asks "is this the same
                # dict?", and two dicts describing one blob are not, so the survivor's own
                # path could be emitted as DELETE - see load_candidates above. Belt and
                # braces with the dedup there: either fix alone closes the hole, and a
                # blob must never be listed as a duplicate of itself.
                keep = r['blob'] == survivor['blob']
                reason = ('survivor: original bytes' if keep and r['scheme'] == 'legacy'
                          else 'survivor: oldest' if keep
                          else f'duplicate of {survivor["blob"]}')
                fh.write(f'{"KEEP" if keep else "DELETE"}\t{token}\t'
                         f'{matter_of(r["blob"])}\t{r["scheme"]}\t{r["lastModified"]}\t'
                         f'{r["blob"]}\t{reason}\n')
                if keep:
                    kept += 1
                else:
                    deleted += 1

    print(f'manifest: {out}')
    print(f'  confirmed duplicate groups : {real_groups:,}')
    print(f'  blobs kept                 : {kept:,}')
    print(f'  blobs marked DELETE        : {deleted:,}')
    if unresolved_groups:
        print(f'  groups skipped, unresolved : {unresolved_groups:,}  '
              f'(a blob would not resolve; the group is left intact)')
    print('\nNothing has been deleted. Review the manifest before any deletion pass exists.')
    return 0


def decode_words(value):
    """Decode RFC 2047 encoded-words, e.g. '=?Windows-1252?Q?RE:_Medical_=97_RSE?='.

    The .msg side hands back the raw encoded form where the .eml side of the same message
    hands back the decoded one, so comparing them undecoded reports a difference that is
    only an encoding. Anything unparseable is returned as-is rather than discarded.
    """
    if not value or '=?' not in value:
        return value or ''
    try:
        import email.header
        return str(email.header.make_header(email.header.decode_header(value)))
    except Exception:                                             # noqa: BLE001
        return value


def describe_blob(storage, key_mod, blob_name):
    """Subject / sender / sent date / size for one blob, whichever scheme it uses.

    Only ever reads metadata. Bodies are never printed - the point is to let a person
    judge whether the survivor and the copies really are one message, which the headers
    settle without putting correspondence on screen.
    """
    import email
    import tempfile
    from email import policy

    if token_from_name(blob_name):                     # ingested .msg: needs the whole file
        try:
            raw, _, total = storage.head_bytes_sized(blob_name, 40 * 1024 * 1024)
        except Exception as e:                                    # noqa: BLE001
            return {'error': type(e).__name__}
        with tempfile.NamedTemporaryFile(suffix='.msg', delete=False) as tf:
            tf.write(raw)
            tmp = tf.name
        try:
            # describe_msg's keys are 'sentUtc' and 'subject'; it returns no sender, so
            # that comes from extract_msg directly. Reading 'sent' here instead of
            # 'sentUtc' silently blanked the date on every ingested blob and made every
            # mixed group report DIFFER - a review tool that cries wolf is worse than none.
            d = key_mod.describe_msg(tmp)
            sender = ''
            try:
                import extract_msg
                m = extract_msg.Message(tmp)
                sender = m.sender or ''
                m.close()
            except Exception:                                     # noqa: BLE001
                pass
            return {'subject': decode_words(d.get('subject')), 'from': decode_words(sender),
                    'sent': d.get('sentUtc') or '', 'size': total, 'error': None}
        except Exception as e:                                    # noqa: BLE001
            return {'error': type(e).__name__}
        finally:
            os.unlink(tmp)

    try:
        raw, _, total = storage.head_bytes_sized(blob_name, RETRY_BYTES)
    except Exception as e:                                        # noqa: BLE001
        return {'error': type(e).__name__}
    msg = email.message_from_bytes(raw, policy=policy.default)
    return {'subject': decode_words(str(msg.get('Subject') or '')),
            'from': decode_words(str(msg.get('From') or '')),
            'sent': key_mod.sent_utc(msg) or '', 'size': total, 'error': None}


def cmd_review(args):
    """Print a readable sample of planned groups, survivor beside the copies it replaces.

    The sample is stratified rather than uniform, because the uniform case is the boring
    one: mixed-scheme groups are where the keep-rule actually makes a choice, and the
    largest groups are where a wrong choice costs most.
    """
    key_mod = load_ingest_key()
    storage = Storage()

    manifest = args.manifest or os.path.join(HERE, 'dedup-manifest.tsv')
    if not os.path.exists(manifest):
        sys.exit(f'no manifest at {manifest}. Run `plan` first.')

    groups = {}
    with open(manifest, encoding='utf-8') as fh:
        fh.readline()
        for line in fh:
            p = line.rstrip('\n').split('\t')
            if len(p) < 7:
                continue
            groups.setdefault(p[1], []).append(
                {'action': p[0], 'matter': p[2], 'scheme': p[3], 'blob': p[5]})

    if args.group:
        chosen = [args.group] if args.group in groups else []
        if not chosen:
            sys.exit(f'token {args.group} is not in the manifest')
    else:
        import random
        rnd = random.Random(args.seed)
        mixed = [t for t, r in groups.items() if len({x['scheme'] for x in r}) > 1]
        legacy_only = [t for t, r in groups.items() if all(x['scheme'] == 'legacy' for x in r)]
        biggest = sorted(groups, key=lambda t: -len(groups[t]))[:200]
        per = max(1, args.sample // 3)
        chosen = []
        pools = [mixed, legacy_only, biggest]
        for pool in pools:
            rnd.shuffle(pool)
            chosen += [t for t in pool if t not in chosen][:per]
        # Three strata of sample//3 leave a remainder, so asking for 100 used to return 99
        # with nothing said about the missing one. Top up from whichever pools still have
        # groups until the requested count is met or the pools are exhausted.
        if len(chosen) < args.sample:
            picked = set(chosen)
            for pool in pools:
                for t in pool:
                    if len(chosen) >= args.sample:
                        break
                    if t not in picked:
                        chosen.append(t)
                        picked.add(t)
        chosen = chosen[:args.sample]

    print(f'{len(groups):,} planned groups; showing {len(chosen)}'
          f'{"" if args.group else " (mixed / legacy-only / largest)"}\n')

    for token in chosen:
        rows = sorted(groups[token], key=lambda r: r['action'] != 'KEEP')
        print('=' * 100)
        print(f'{token}   matter {rows[0]["matter"]}   {len(rows)} copies')
        seen = set()
        for r in rows:
            d = describe_blob(storage, key_mod, r['blob'])   # fetched once, used twice below
            mark = 'KEEP  ' if r['action'] == 'KEEP' else 'DELETE'
            if d.get('error'):
                print(f'  {mark} {r["scheme"]:<9} !! could not read: {d["error"]}')
                continue
            size = f'{d["size"]:,}' if d['size'] else '?'
            print(f'  {mark} {r["scheme"]:<9} {d["sent"]:<21} {size:>10} bytes')
            print(f'         from    {d["from"][:78]}')
            print(f'         subject {d["subject"][:78]}')
            # Collapse whitespace before comparing: a long .eml Subject arrives folded
            # across lines while the .msg copy of the same subject does not, and an
            # unnormalised compare would call that a difference.
            subj_norm = ' '.join((d['subject'] or '').split()).lower()
            seen.add((d['sent'], subj_norm))

        # Report which field disagrees, because the two mean very different things. A
        # differing sent date questions the grouping itself. A differing subject usually
        # does not: the gateway prepends '[EXTERNAL] ' per recipient, so one delivered
        # copy of a message carries it and another does not. Collapsing both into one
        # DIFFER trains a reviewer to wave the flag through.
        dates = {s for s, _ in seen}
        subjects = {j for _, j in seen}
        if len(dates) > 1:
            print('  -> SENT DATES DIFFER - inspect before trusting this group')
        elif len(subjects) > 1:
            stripped = {re.sub(r'^\s*(\[external\]|\[suspicious\])\s*', '', j)
                        for j in subjects}
            print('  -> agree on sent date; subjects differ only by a gateway prefix'
                  if len(stripped) == 1 else
                  '  -> agree on sent date; SUBJECTS DIFFER - worth a look')
        else:
            print('  -> AGREE on sent date + subject')
    print('\nNothing has been deleted.')
    return 0


def blob_ext(blob_name):
    """.msg or .eml, off the blob name alone - never guessed from content.

    Used only to label a mismatch. A real mismatch here is far more likely to be the
    untested .msg precedence rules (MAPI messageId fallback, Date-vs-SentOn) than a
    freak blob, so the report needs to say which route produced the disagreeing blob,
    not just that one exists.
    """
    return blob_name.rsplit('.', 1)[-1].lower() if '.' in blob_name else '?'


def cmd_conformance(args):
    """Check the deployed Function reproduces the tokens in real ingested blob names.

    selftest proves ingest-key.py still agrees with what it wrote. This proves the C#
    Function agrees too - the claim that lets the pipeline and the ingest share one
    identity. Sends only headers, never whole messages.
    """
    import urllib.error
    import urllib.request
    key_mod = load_ingest_key()
    storage = Storage()

    named = []
    with open(args.index, encoding='utf-8') as fh:
        fh.readline()
        for line in fh:
            blob = line.split('\t', 1)[0]
            if token_from_name(blob):
                named.append(blob)
            if len(named) >= args.sample * 4:
                break
    sample = named[::4][:args.sample]
    print(f'checking {len(sample)} ingested blobs against {args.func}\n')

    ok = bad = failed = 0
    bad_by_ext = {}
    for i, blob in enumerate(sample, 1):
        expected = token_from_name(blob)
        ext = blob_ext(blob)
        try:
            raw, _, _ = storage.head_bytes_sized(blob, 40 * 1024 * 1024)
        except Exception as e:                                    # noqa: BLE001
            failed += 1
            print(f'  [{i}/{len(sample)}] fetch failed ({type(e).__name__}) .{ext} {blob}')
            continue
        req = urllib.request.Request(args.func, data=raw,
                                     headers={'Content-Type': 'application/octet-stream'})
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                got = json.loads(resp.read()).get('token')
        except urllib.error.HTTPError as e:
            failed += 1
            print(f'  [{i}/{len(sample)}] function call failed (HTTP {e.code}) .{ext} {blob}')
            continue
        except (urllib.error.URLError, ValueError) as e:
            # Not an HTTP error response from the Function - the URL itself could not be
            # reached at all (DNS, connection refused, timeout, or a malformed --func).
            # Retrying the rest of the sample against a dead URL would just repeat this
            # forty times and look like a hang; say what is wrong, once, and stop.
            print(f'\ncould not reach {args.func}\n  {getattr(e, "reason", e)}\n'
                  f'Checked {i - 1} of {len(sample)} before this. Confirm the Function is '
                  f'deployed and --func (including ?code=) is correct, then re-run.')
            return 1
        except Exception as e:                                    # noqa: BLE001
            failed += 1
            print(f'  [{i}/{len(sample)}] function call failed ({type(e).__name__}) .{ext} {blob}')
            continue
        if got == expected:
            ok += 1
        else:
            bad += 1
            bad_by_ext[ext] = bad_by_ext.get(ext, 0) + 1
            print(f'  [{i}/{len(sample)}] MISMATCH .{ext}  name={expected}  function={got}\n'
                  f'           {blob}')

    print(f'\nmatched {ok}, mismatched {bad}, unreadable {failed}')
    if bad:
        breakdown = ', '.join(f'{n} .{ext}' for ext, n in sorted(bad_by_ext.items()))
        print(f'  mismatches by route: {breakdown}')
        if bad_by_ext.get('msg') and not bad_by_ext.get('eml'):
            print('  All mismatches are .msg: look at the MAPI messageId fallback and the\n'
                  '  Date-vs-SentOn precedence in DedupToken.FromBytes - those two rules have\n'
                  '  no unit test and this sample is the only thing that has ever exercised\n'
                  '  them against real mail. This is not a strange blob.')
        elif bad_by_ext.get('eml') and not bad_by_ext.get('msg'):
            print('  All mismatches are .eml: the MIME branch of DedupToken.FromBytes or its\n'
                  '  Message-ID/Date header handling is the more likely place to look.')
        print('\nThe Function does not reproduce the tokens already in the container.\n'
              'Do not wire anything to it until this is understood.')
        return 1
    if not ok:
        print('\nNothing verified. Treat the Function as unproven.')
        return 1
    print('\nThe Function agrees with the names already in the container.')
    return 0


def main():
    # The Windows console is cp1252, and these subjects are not. A single emoji in one
    # subject killed a review run at group 16 of 30 with UnicodeEncodeError - the same
    # family of failure as the 87 spurious 404s from non-ASCII blob names and the
    # Content-Disposition crashes, all in this one corpus. Replace what cannot be encoded
    # rather than letting a character abort the pass.
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    except (AttributeError, OSError):
        pass

    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    st = sub.add_parser('selftest', help='prove the token function against real blob names')
    st.add_argument('--sample', type=int, default=40)
    st.add_argument('--index', default=INDEX)

    sub.add_parser('selftest-grouping',
                   help='offline: prove a repeated index row cannot become a delete order')

    pl = sub.add_parser('plan', help='write the dry-run manifest')
    pl.add_argument('--out')
    pl.add_argument('--index', default=INDEX)
    pl.add_argument('--parallel', type=int, default=24)
    pl.add_argument('--limit', type=int, help='stop after N candidate groups (for a trial run)')

    rv = sub.add_parser('review', help='print a readable sample of planned groups')
    rv.add_argument('--sample', type=int, default=12)
    rv.add_argument('--manifest')
    rv.add_argument('--group', help='inspect one token instead of a sample')
    rv.add_argument('--seed', type=int, default=1, help='same seed gives the same sample')

    cf = sub.add_parser('conformance', help='check the deployed Function against real blob names')
    cf.add_argument('--sample', type=int, default=40)
    cf.add_argument('--index', default=INDEX)
    cf.add_argument('--func', required=True, help='DedupTokenFunc URL including ?code=')

    args = ap.parse_args()
    if args.cmd == 'selftest-grouping':
        return cmd_selftest_grouping(args)
    if args.cmd == 'review':
        return cmd_review(args)
    if args.cmd == 'conformance':
        if not os.path.exists(args.index):
            sys.exit(f'no Message-ID index at {args.index}')
        return cmd_conformance(args)
    if not os.path.exists(args.index):
        sys.exit(f'no Message-ID index at {args.index}\n'
                 f'It is a gitignored build artefact - pass --index <path> to the copy you\n'
                 f'have, or rebuild it with build-messageid-index.ps1.')
    return cmd_selftest(args) if args.cmd == 'selftest' else cmd_plan(args)


if __name__ == '__main__':
    sys.exit(main())
