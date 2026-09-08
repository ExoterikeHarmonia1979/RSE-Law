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
            by_mid.setdefault(parts[1], []).append(parts[0])

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
                keep = r is survivor
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)

    st = sub.add_parser('selftest', help='prove the token function against real blob names')
    st.add_argument('--sample', type=int, default=40)
    st.add_argument('--index', default=INDEX)

    pl = sub.add_parser('plan', help='write the dry-run manifest')
    pl.add_argument('--out')
    pl.add_argument('--index', default=INDEX)
    pl.add_argument('--parallel', type=int, default=24)
    pl.add_argument('--limit', type=int, help='stop after N candidate groups (for a trial run)')

    args = ap.parse_args()
    if not os.path.exists(args.index):
        sys.exit(f'no Message-ID index at {args.index}\n'
                 f'It is a gitignored build artefact - pass --index <path> to the copy you\n'
                 f'have, or rebuild it with build-messageid-index.ps1.')
    return cmd_selftest(args) if args.cmd == 'selftest' else cmd_plan(args)


if __name__ == '__main__':
    sys.exit(main())
