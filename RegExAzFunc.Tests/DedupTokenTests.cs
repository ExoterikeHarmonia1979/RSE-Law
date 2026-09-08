using System.Text;
using Company.Function;

namespace RegExAzFunc.Tests;

public class DedupTokenTests
{
    [Fact]
    public void Key_matches_the_python_reference()
    {
        // sha256("<abc@example.com>" lowercased, bare, + "|" + sent) truncated to 22 hex
        // chars, prefixed 'k'. Computed with ingest-key.py's dedup_key().
        string? token = DedupToken.Key("abc@example.com", "2026-03-20T21:52:57Z");

        Assert.NotNull(token);
        Assert.StartsWith("k", token);
        Assert.Equal(23, token!.Length);          // 'k' + 22 hex
        Assert.Matches("^k[0-9a-f]{22}$", token);

        // The shape assertions above cannot catch a wrong delimiter, wrong case-folding,
        // or a truncated-instead-of-hashed input that still happens to produce valid-looking
        // hex - exactly the class of bug this test exists to catch. Pin the literal value
        // ingest-key.py's dedup_key('abc@example.com', '2026-03-20T21:52:57Z') actually
        // produces, so a drift in the algorithm itself fails loudly here.
        Assert.Equal("k5e610767040b7fc3c8b636", token);
    }

    [Fact]
    public void Key_is_stable_and_case_folds_the_message_id()
    {
        Assert.Equal(DedupToken.Key("ABC@Example.COM", "2026-03-20T21:52:57Z"),
                     DedupToken.Key("abc@example.com", "2026-03-20T21:52:57Z"));
    }

    [Fact]
    public void Key_needs_both_parts()
    {
        Assert.Null(DedupToken.Key(null, "2026-03-20T21:52:57Z"));
        Assert.Null(DedupToken.Key("abc@example.com", null));
        Assert.Null(DedupToken.Key("", ""));
    }

    [Fact]
    public void CleanMid_strips_control_characters_before_the_angle_brackets()
    {
        // A real message in the June 2024 batch carried a NUL immediately after '>'.
        // Stripping <> first cannot reach it, and the id would then key differently from
        // the same message read as .msg - dedup broken with nothing visible to show it.
        Assert.Equal("abc@example.com", DedupToken.CleanMid("<abc@example.com>\0"));
        Assert.Equal("abc@example.com", DedupToken.CleanMid("  <abc@example.com>  "));
        Assert.Equal("abc@example.com", DedupToken.CleanMid("abc@example.com"));
    }

    [Fact]
    public void CleanMid_returns_null_for_nothing_usable()
    {
        Assert.Null(DedupToken.CleanMid(null));
        Assert.Null(DedupToken.CleanMid("   "));
        Assert.Null(DedupToken.CleanMid("<>"));
    }

    [Fact]
    public void SentUtc_converts_an_offset_to_utc_to_the_second()
    {
        Assert.Equal("2026-05-04T17:33:58Z", DedupToken.SentUtc("Mon, 4 May 2026 10:33:58 -0700"));
        Assert.Equal("2026-03-20T21:52:57Z", DedupToken.SentUtc("Fri, 20 Mar 2026 21:52:57 +0000"));
    }

    [Fact]
    public void SentUtc_returns_null_for_an_unparseable_date()
    {
        Assert.Null(DedupToken.SentUtc(null));
        Assert.Null(DedupToken.SentUtc("not a date"));
    }

    [Fact]
    public void SentUtc_accepts_graphs_iso8601_sentDateTime_as_well_as_rfc5322()
    {
        // Graph's sentDateTime (the ?from=fields sweep route) is ISO-8601, which
        // DateUtils.TryParse (RFC 822/2822 only) does not accept. Without this fallback
        // every item through that route keys to null and the endpoint is a permanent
        // no-op - worse than the "affordably wrong" the design intended, because it
        // re-queues the whole corpus forever instead of just being wrong sometimes.
        Assert.Equal("2026-03-20T21:52:57Z", DedupToken.SentUtc("2026-03-20T21:52:57Z"));
        Assert.Equal("2026-03-20T21:52:57Z", DedupToken.SentUtc("2026-03-20T21:52:57.0000000+00:00"));

        // The RFC 5322 path this fallback sits behind must be unchanged: it is what the
        // 401,170 existing tokens were computed from.
        Assert.Equal("2026-05-04T17:33:58Z", DedupToken.SentUtc("Mon, 4 May 2026 10:33:58 -0700"));
        Assert.Equal("2026-03-20T21:52:57Z", DedupToken.SentUtc("Fri, 20 Mar 2026 21:52:57 +0000"));
    }

    [Fact]
    public void FromBytes_reads_an_eml_header_block()
    {
        byte[] eml = Encoding.ASCII.GetBytes(string.Join("\r\n",
            "From: a@example.com",
            "To: b@example.com",
            "Subject: hello",
            "Date: Fri, 20 Mar 2026 21:52:57 +0000",
            "Message-ID: <abc@example.com>",
            "",
            "body text"));

        var (token, mid, sent) = DedupToken.FromBytes(eml);

        Assert.Equal("abc@example.com", mid);
        Assert.Equal("2026-03-20T21:52:57Z", sent);
        Assert.Equal(DedupToken.Key("abc@example.com", "2026-03-20T21:52:57Z"), token);
    }

    [Fact]
    public void FromBytes_returns_no_token_when_identity_is_missing()
    {
        byte[] noId = Encoding.ASCII.GetBytes("Subject: hello\r\n\r\nbody");

        var (token, _, _) = DedupToken.FromBytes(noId);

        Assert.Null(token);
    }
}
