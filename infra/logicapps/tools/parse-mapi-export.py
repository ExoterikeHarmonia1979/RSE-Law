"""Extract dedup keys from Graph exportItems payloads.

`POST /beta/admin/exchange/mailboxes/{id}/exportItems` returns an MS-OXCFXICS
FastTransfer stream in `data`, not MIME. There are no RFC 5322 headers to read, so the
identity a dedup has to key on lives in MAPI properties.

Stream framing, established by locating a known value and reading backwards from it:

    [4-byte property tag, little-endian][4-byte byte-count][value bytes]

where the tag packs as (propId << 16) | propType, so the little-endian bytes run
type-lo type-hi id-lo id-hi. A PT_UNICODE value is UTF-16LE; PT_STRING8 is 8-bit; both
carry a trailing NUL inside the counted length.

Two properties matter, and the second is the one that makes this worth writing:

  0x007D PidTagTransportMessageHeaders - the original header block. Present only for mail
         that traversed SMTP, so absent on internal Outlook-to-Outlook mail (~26% here).
  0x007F PidTagTnefCorrelationKey      - holds the Message-ID, and is set independently of
         the header block. This is what recovers an id for headerless items.

Do NOT read the first <...@...> in the buffer: From/To addresses precede Message-ID, so
that keys on the wrong value for roughly two thirds of items.
"""
import base64
import re
import struct

PT_STRING8 = 0x001E
PT_UNICODE = 0x001F
PT_BINARY  = 0x0102
PT_SYSTIME = 0x0040

PROPS = {
    'transportHeaders': (0x007D, (PT_UNICODE, PT_STRING8)),
    'tnefCorrelation':  (0x007F, (PT_BINARY,)),
    'internetMessageId':(0x1035, (PT_UNICODE, PT_STRING8)),
    'subject':          (0x0037, (PT_UNICODE, PT_STRING8)),
    'normalizedSubject':(0x0E1D, (PT_UNICODE, PT_STRING8)),
    'submitTime':       (0x0039, (PT_SYSTIME,)),
    'senderEmail':      (0x0C1F, (PT_UNICODE, PT_STRING8)),
}

MID_IN_HEADERS = re.compile(r'Message-ID:\s*<([^>\r\n]+)>', re.I)
ANGLE_ID       = re.compile(r'^<?([^<>\r\n]{5,300}@[^<>\r\n]{3,200})>?$')
MAX_VALUE      = 4 * 1024 * 1024


def _tag_bytes(prop_id, prop_type):
    return struct.pack('<HH', prop_type, prop_id)


def _decode(raw, prop_type):
    if prop_type == PT_UNICODE:
        s = raw.decode('utf-16le', errors='ignore')
    else:
        # PT_BINARY holding a Message-ID is ASCII; PT_STRING8 is 8-bit text
        s = raw.decode('latin-1', errors='ignore')
    return s.rstrip('\x00').strip()


def read_property(buf, prop_id, prop_types):
    """Find a property by tag and return its decoded value, or None.

    Scans for the tag rather than walking the stream: the FastTransfer grammar nests
    (folders, recipients, attachments each open sub-streams) and a full walk would have
    to model all of it. Scanning is safe here because the tag is checked against a
    plausible length and the value is validated by the caller.
    """
    for prop_type in prop_types:
        tag = _tag_bytes(prop_id, prop_type)
        start = 0
        while True:
            i = buf.find(tag, start)
            if i < 0:
                break
            start = i + 4
            off = i + 4
            if off + 4 > len(buf):
                continue
            n = struct.unpack_from('<I', buf, off)[0]
            if n == 0 or n > MAX_VALUE or off + 4 + n > len(buf):
                continue
            raw = buf[off + 4: off + 4 + n]
            if prop_type == PT_SYSTIME:
                if n != 8:
                    continue
                return struct.unpack('<Q', raw)[0]
            val = _decode(raw, prop_type)
            if val:
                return val
    return None


def decodings(buf):
    """The stream mixes encodings: some header blocks are UTF-16LE, some 8-bit.

    Measured on 100 items: 47 of the recoverable ids were UTF-16LE and 27 were 8-bit,
    so trying only one encoding silently loses about a quarter of them.
    """
    yield buf.decode('utf-16le', errors='ignore')
    yield buf.decode('latin-1', errors='ignore')


def header_block_message_id(buf):
    """Message-ID from the transport headers, located by text scan.

    The tag-scan in read_property does not find 0x007D in these streams - the string
    properties are not framed the way PT_BINARY is - but the header text is plainly
    present, so scan for it instead of insisting on the property.

    Folding matters: the value routinely appears as "Message-ID:\\r\\n <id>", which is
    why MID_IN_HEADERS allows whitespace (including newlines) after the colon.
    """
    for text in decodings(buf):
        m = MID_IN_HEADERS.search(text)
        if m:
            return m.group(1).strip()
    return None


def message_id(buf):
    """Return (message_id, source) using the most trustworthy route available.

    Order is deliberate. The header block is authoritative for the message's own
    identity; PidTagTnefCorrelationKey usually matches it but can differ (1 of 30 items
    where both were present), so it is a fallback rather than a peer. It earns its place
    by covering the ~26% of items that never traversed SMTP and so have no headers at all.
    """
    mid = header_block_message_id(buf)
    if mid:
        return mid, 'transportHeaders'

    imid = read_property(buf, *PROPS['internetMessageId'])
    if imid:
        m = ANGLE_ID.match(imid)
        if m:
            return m.group(1).strip(), 'internetMessageId'

    tnef = read_property(buf, *PROPS['tnefCorrelation'])
    if tnef:
        m = ANGLE_ID.match(tnef)
        if m:
            return m.group(1).strip(), 'tnefCorrelationKey'

    return None, None


def filetime_to_iso(ft):
    """Windows FILETIME (100ns since 1601) -> ISO 8601, or None."""
    if not ft or ft <= 0:
        return None
    import datetime
    try:
        epoch = datetime.datetime(1601, 1, 1, tzinfo=datetime.timezone.utc)
        return (epoch + datetime.timedelta(microseconds=ft // 10)).isoformat()
    except (OverflowError, OSError, ValueError):
        return None


HDR_FIELD = {
    'subject': re.compile(r'^Subject:\s*(.+?)(?=\r?\n\S|\r?\n\r?\n|\Z)', re.I | re.M | re.S),
    'date':    re.compile(r'^Date:\s*([^\r\n]+)', re.I | re.M),
    'from':    re.compile(r'^From:\s*([^\r\n]+)', re.I | re.M),
}


def header_fields(buf):
    """Subject/Date/From from the transport header block, when there is one.

    The tag-scan does not reach the string properties, so for items that traversed SMTP
    these come from the header text. Items without headers fall back to MAPI properties,
    which is where the discriminator for the internal-mail tier has to come from.
    """
    for text in decodings(buf):
        if 'Received:' not in text and 'Subject:' not in text:
            continue
        out = {}
        for key, rx in HDR_FIELD.items():
            m = rx.search(text)
            if m:
                out[key] = re.sub(r'\s+', ' ', m.group(1)).strip()
        if out:
            return out
    return {}


def dedup_key(data_b64_or_bytes):
    """Full dedup key for one exported item.

    Message-ID alone is not safe: in this corpus 3,835 groups of genuinely different
    messages share one, so the sent date and subject are part of the key, not decoration.
    """
    buf = (base64.b64decode(data_b64_or_bytes)
           if isinstance(data_b64_or_bytes, str) else data_b64_or_bytes)
    mid, src = message_id(buf)
    hdrs = header_fields(buf)
    subject = (hdrs.get('subject')
               or read_property(buf, *PROPS['subject'])
               or read_property(buf, *PROPS['normalizedSubject']))
    sent = hdrs.get('date') or filetime_to_iso(read_property(buf, *PROPS['submitTime']))
    return {
        'messageId': mid,
        'messageIdSource': src,
        'subject': subject,
        'sentUtc': sent,
        'sender': hdrs.get('from') or read_property(buf, *PROPS['senderEmail']),
        'bytes': len(buf),
    }
