"""Blob name and dedup key for ingested archive mail.

Implements the scheme recorded in INGEST-BLOB-NAMING.md:

    key   = sha256( lower(message-id) + '|' + sent-date-utc-to-the-second )
    token = 'k' + first 22 hex chars
    name  = <subject capped 150> [<token>].eml

The eDiscovery export route delivers PSTs, which readpst/libpff turn into ordinary RFC
5322 .eml files - so identity comes from real headers here, not from MAPI properties.
(parse-mapi-export.py covers the Graph exportItems route, which returns MAPI
FastTransfer instead. Both produce the same key; only the source differs.)

Message-ID alone is NOT a safe key: 3,835 groups of genuinely different messages in this
corpus share one, because Outlook reuses the header across separately composed mail. The
sent date is what separates them, so it is part of the key rather than metadata.

Usage
    python ingest-key.py plan  <dir-of-eml> [--index messageid-index.tsv]
    python ingest-key.py check <file.eml> ...
"""
import csv
import email
import email.utils
import hashlib
import os
import re
import sys
from email import policy

# Matches the sanitising the Logic App already applies to blob stems, so ingested names
# sit alongside the existing ones instead of introducing a second convention.
BAD = re.compile(r'[\\/:*?"<>|\r\n\t]+')
WS = re.compile(r'\s+')
SUBJECT_CAP = 150


def clean_stem(subject):
    s = BAD.sub('_', subject or '')
    s = WS.sub(' ', s).strip()
    if not s:
        s = '(no subject)'
    return s[:SUBJECT_CAP].strip()


def sent_utc(msg):
    """RFC 5322 Date -> 'YYYY-MM-DDTHH:MM:SSZ', or None if unparseable."""
    raw = msg.get('Date')
    if not raw:
        return None
    try:
        dt = email.utils.parsedate_to_datetime(raw)
    except (TypeError, ValueError):
        return None
    if dt is None:
        return None
    if dt.tzinfo is not None:
        import datetime
        dt = dt.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    return dt.strftime('%Y-%m-%dT%H:%M:%SZ')


def message_id(msg):
    mid = msg.get('Message-ID') or msg.get('Message-Id')
    if not mid:
        return None
    mid = mid.strip()
    if mid.startswith('<') and mid.endswith('>'):
        mid = mid[1:-1]
    return mid.strip() or None


def dedup_key(mid, sent):
    """Stable identity for one message. Both parts required."""
    if not mid or not sent:
        return None
    h = hashlib.sha256(f'{mid.lower()}|{sent}'.encode('utf-8')).hexdigest()
    return 'k' + h[:22]


def describe(path):
    with open(path, 'rb') as f:
        msg = email.message_from_binary_file(f, policy=policy.default)
    mid = message_id(msg)
    sent = sent_utc(msg)
    subj = None
    try:
        subj = msg.get('Subject')
    except Exception:
        pass
    token = dedup_key(mid, sent)
    return {
        'path': path,
        'messageId': mid,
        'sentUtc': sent,
        'subject': subj,
        'token': token,
        'blobName': f'{clean_stem(subj)} [{token}].eml' if token else None,
    }


def load_index(index_path):
    """message-id -> count of blobs already carrying it."""
    seen = {}
    with open(index_path, encoding='utf-8', errors='replace', newline='') as f:
        r = csv.reader(f, delimiter='\t')
        next(r, None)
        for rec in r:
            if len(rec) >= 3 and rec[2].strip() == 'ok' and rec[1].strip():
                mid = rec[1].strip().lower()
                seen[mid] = seen.get(mid, 0) + 1
    return seen


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    mode, args = sys.argv[1], sys.argv[2:]

    if mode == 'check':
        for p in args:
            d = describe(p)
            print(f'{os.path.basename(p)}')
            print(f'   message-id : {d["messageId"]}')
            print(f'   sent       : {d["sentUtc"]}')
            print(f'   token      : {d["token"]}')
            print(f'   blob name  : {d["blobName"]}')
        return 0

    if mode == 'plan':
        src = args[0]
        index_path = None
        if '--index' in args:
            index_path = args[args.index('--index') + 1]
        idx = load_index(index_path) if index_path else {}
        print(f'index: {len(idx):,} distinct message-ids')

        files = []
        for root, _dirs, names in os.walk(src):
            for n in names:
                if n.lower().endswith('.eml'):
                    files.append(os.path.join(root, n))
        print(f'source: {len(files):,} .eml files under {src}')

        keyed = unkeyed = already = fresh = 0
        by_token = {}
        for p in files:
            try:
                d = describe(p)
            except Exception as e:
                print(f'  PARSE FAILED {p}: {e}')
                unkeyed += 1
                continue
            if not d['token']:
                unkeyed += 1
                continue
            keyed += 1
            by_token.setdefault(d['token'], []).append(d)
            if d['messageId'].lower() in idx:
                already += 1
            else:
                fresh += 1

        print()
        print(f'  keyed              : {keyed:,}')
        print(f'  no usable key      : {unkeyed:,}   (missing Message-ID or Date)')
        print(f'  message-id already in the archive : {already:,}')
        print(f'  not seen before                   : {fresh:,}')
        dupes = {t: v for t, v in by_token.items() if len(v) > 1}
        print(f'  identical keys within this batch  : {len(dupes):,} '
              f'(same message exported twice - safe, they overwrite)')
        return 0

    print(__doc__)
    return 2


if __name__ == '__main__':
    raise SystemExit(main())
