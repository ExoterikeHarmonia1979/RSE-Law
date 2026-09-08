using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using MimeKit;
using MimeKit.Utils;

namespace Company.Function;

/// <summary>
/// The identity of an archived message: sha256 over its Message-ID and sent date.
///
/// This is a port of ingest-key.py's dedup_key/clean_mid/sent_utc, and it must stay one.
/// 401,170 blob names already encode that function's output, so a drift of one character
/// here does not throw - it silently writes a second copy of a message that is already
/// archived, which is the exact defect this whole change exists to remove.
/// </summary>
internal static class DedupToken
{
    private static readonly Regex Ctrl = new(@"[\x00-\x1f\x7f]+", RegexOptions.Compiled);

    /// <summary>
    /// Normalise a Message-ID to its bare form.
    /// <para>
    /// Control characters go FIRST. A real message in the June 2024 batch carried a NUL
    /// immediately after the closing '&gt;', so stripping '&lt;&gt;' first could not reach
    /// it and the id kept the bracket - keying that message differently from the same
    /// message read as .msg, and breaking dedup with no visible error.
    /// </para>
    /// </summary>
    internal static string? CleanMid(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) { return null; }
        string mid = Ctrl.Replace(raw, "").Trim().Trim('<', '>').Trim();
        return mid.Length == 0 ? null : mid;
    }

    /// <summary>
    /// RFC 5322 Date, or ISO-8601 -&gt; 'yyyy-MM-ddTHH:mm:ssZ', or null if unparseable.
    /// <para>
    /// Two input shapes reach this: the transport Date header (RFC 822/2822, from both the
    /// .eml route and the .msg header block), and Graph's sentDateTime (ISO-8601, from the
    /// ?from=fields sweep route). RFC 2822 is tried FIRST and must keep working exactly as
    /// it does now - 401,170 existing tokens depend on it. ISO-8601 is the fallback: without
    /// it, every item through ?from=fields keys to null and the sweep endpoint is a
    /// permanent no-op, re-queueing the whole corpus forever instead of the "affordably
    /// wrong" the design intended.
    /// </para>
    /// </summary>
    internal static string? SentUtc(string? rawDate)
    {
        if (string.IsNullOrWhiteSpace(rawDate)) { return null; }
        // MimeKit parses the RFC 2822 forms this corpus actually contains, including the
        // obsolete zone names DateTimeOffset.Parse rejects.
        if (DateUtils.TryParse(rawDate, out DateTimeOffset dt))
        {
            return dt.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss") + "Z";
        }
        if (DateTimeOffset.TryParse(rawDate, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out DateTimeOffset iso))
        {
            return iso.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss") + "Z";
        }
        return null;
    }

    /// <summary>Stable identity for one message. Both parts required.</summary>
    internal static string? Key(string? mid, string? sent)
    {
        if (string.IsNullOrEmpty(mid) || string.IsNullOrEmpty(sent)) { return null; }
        byte[] hash = SHA256.HashData(Encoding.UTF8.GetBytes($"{mid.ToLowerInvariant()}|{sent}"));
        return "k" + Convert.ToHexString(hash).ToLowerInvariant()[..22];
    }

    private static ReadOnlySpan<byte> Ole2Signature => [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];

    /// <summary>
    /// Derive identity from raw message bytes - the same source ingest-key.py used.
    /// <para>
    /// Handles both formats it handles, because this is meant to be the one implementation:
    /// MIME from the pipeline, and the compound-file .msg the ingest wrote. The conformance
    /// check posts real ingested .msg blobs, so a MIME-only version would fail the very
    /// test that proves this agrees with the 401,170 tokens already in the container.
    /// </para>
    /// <para>
    /// Format is decided by the OLE2 signature, never by an extension. The ingest derived
    /// blob names from subjects, so a name says nothing about content.
    /// </para>
    /// </summary>
    internal static (string? Token, string? MessageId, string? SentUtc) FromBytes(byte[] bytes)
    {
        try
        {
            if (bytes.Length >= 8 && bytes.AsSpan(0, 8).SequenceEqual(Ole2Signature))
            {
                using var msgStream = new MemoryStream(bytes);
                using var msg = new MsgReader.Outlook.Storage.Message(msgStream);
                // MsgReader 6.1.0 has no GetEmailHeaders() - the brief's guess. The
                // transport Message-ID lives on the parsed Headers property instead
                // (MsgReader.Mime.Header.MessageHeader.MessageId), which is null when the
                // message never carried transport headers (internal Outlook-to-Outlook
                // mail - per MsgReader's own doc comment on Headers).
                //
                // Precedence mirrors ingest-key.py's describe_msg() exactly: the transport
                // header block first for BOTH mid and sent - it is the message's own record
                // of itself, and it is what the .eml route reads, so the two routes agree.
                // MAPI properties are the fallback, used only for the roughly quarter of
                // this archive that never traversed SMTP and so has no headers at all.
                // Using MAPI SentOn unconditionally (as opposed to only as a fallback) would
                // silently produce a DIFFERENT non-null token whenever it disagrees with the
                // header Date - relay delay, clock skew, a timezone bug anywhere in a
                // multi-year corpus - which is the exact silent-duplicate defect this whole
                // change exists to remove.
                var hdrs = msg.Headers;
                string? msgMid = CleanMid(hdrs?.MessageId) ?? CleanMid(msg.Id);
                string? msgSent = SentUtc(hdrs?.Date);
                if (msgSent == null && msg.SentOn.HasValue)
                {
                    msgSent = msg.SentOn.Value.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss") + "Z";
                }
                return (Key(msgMid, msgSent), msgMid, msgSent);
            }

            using var stream = new MemoryStream(bytes);
            var parser = new MimeParser(stream, MimeFormat.Entity);
            MimeMessage message = parser.ParseMessage();
            string? mid = CleanMid(message.Headers["Message-ID"] ?? message.Headers["Message-Id"]);
            string? sent = SentUtc(message.Headers["Date"]);
            return (Key(mid, sent), mid, sent);
        }
        catch (Exception)
        {
            // A truncated or corrupt message has no identity. Callers fall back; they never
            // fail the archive over it.
            return (null, null, null);
        }
    }
}
