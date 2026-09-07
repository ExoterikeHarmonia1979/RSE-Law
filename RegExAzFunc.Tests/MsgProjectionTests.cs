using System.Text.Json;
using Company.Function;

namespace RegExAzFunc.Tests;

public class MsgProjectionTests
{
    private sealed class FakeMsg : IMsgMessage
    {
        public string Subject { get; init; } = "";
        public string From { get; init; } = "";
        public IReadOnlyList<string> To { get; init; } = Array.Empty<string>();
        public IReadOnlyList<string> Cc { get; init; } = Array.Empty<string>();
        public DateTimeOffset? Sent { get; init; }
        public string? BodyHtml { get; init; }
        public string BodyText { get; init; } = "";
        public IReadOnlyList<MsgAttachment> Attachments { get; init; } = Array.Empty<MsgAttachment>();
    }

    [Fact]
    public void LooksLikeCompoundFile_recognises_the_ole2_signature()
    {
        byte[] msg = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0x00, 0x00];
        Assert.True(MsgProjection.LooksLikeCompoundFile(msg));
    }

    [Fact]
    public void LooksLikeCompoundFile_rejects_mime_and_short_input()
    {
        Assert.False(MsgProjection.LooksLikeCompoundFile("From: a@b.com\r\n"u8));
        Assert.False(MsgProjection.LooksLikeCompoundFile([0xD0, 0xCF]));
    }

    [Fact]
    public void ToPreview_carries_the_headers_across()
    {
        var msg = new FakeMsg
        {
            Subject = "Re: Hearing",
            From = "Scott Dallas <dallas@rse-law.com>",
            To = ["Daniel Eisenberg <dan@rse-law.com>"],
            Cc = ["RSE Matters <matters@rse-law.com>"],
            Sent = new DateTimeOffset(2025, 3, 4, 17, 33, 58, TimeSpan.Zero),
            BodyText = "Holding off until Friday."
        };

        PreviewDto dto = MsgProjection.ToPreview(msg, html => html);

        Assert.Equal("Re: Hearing", dto.Subject);
        Assert.Equal("Scott Dallas <dallas@rse-law.com>", dto.From);
        Assert.Equal(["Daniel Eisenberg <dan@rse-law.com>"], dto.To);
        Assert.Equal(["RSE Matters <matters@rse-law.com>"], dto.Cc);
        Assert.Equal("2025-03-04T17:33:58.0000000+00:00", dto.Date);
        Assert.Equal("Holding off until Friday.", dto.TextBody);
        Assert.Null(dto.HtmlBody);
    }

    [Fact]
    public void ToPreview_sends_html_through_the_sanitizer()
    {
        var msg = new FakeMsg { BodyHtml = "<p onclick='x()'>hi</p>" };

        PreviewDto dto = MsgProjection.ToPreview(msg, html => html.Replace(" onclick='x()'", ""));

        Assert.Equal("<p>hi</p>", dto.HtmlBody);
    }

    [Fact]
    public void ToPreview_reports_attachment_names_and_sizes()
    {
        var msg = new FakeMsg
        {
            Attachments = [new MsgAttachment("brief.pdf", new byte[2048])]
        };

        PreviewDto dto = MsgProjection.ToPreview(msg, html => html);

        Assert.Single(dto.Attachments);
        Assert.Equal("brief.pdf", dto.Attachments[0].Name);
        Assert.Equal(2048, dto.Attachments[0].SizeBytes);
    }

    [Fact]
    public void ToPreview_leaves_an_undated_message_with_an_empty_date()
    {
        PreviewDto dto = MsgProjection.ToPreview(new FakeMsg(), html => html);
        Assert.Equal("", dto.Date);
    }

    [Fact]
    public void PreviewDto_serialises_with_the_keys_the_web_part_already_reads()
    {
        // IEmailItem.ts consumes these exact names; renaming one silently empties the pane.
        string json = JsonSerializer.Serialize(MsgProjection.ToPreview(new FakeMsg(), h => h));

        foreach (string key in new[] { "subject", "from", "to", "cc", "date", "htmlBody", "textBody", "attachments" })
        {
            Assert.Contains($"\"{key}\":", json);
        }
    }
}
