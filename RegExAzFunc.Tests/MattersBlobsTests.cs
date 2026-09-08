using Company.Function;

namespace RegExAzFunc.Tests;

public class MattersBlobsTests
{
    [Fact]
    public void DecodeStoragePath_passes_a_plain_url_through()
    {
        const string url = "https://samatters.blob.core.windows.net/matters/120.057/Emails/a.eml";
        Assert.Equal(url, MattersBlobs.DecodeStoragePath(url));
    }

    [Fact]
    public void DecodeStoragePath_decodes_the_indexer_token_with_its_padding_digit()
    {
        // UrlTokenEncode: url-safe base64 plus a trailing count of stripped '=' padding.
        const string plain = "https://samatters.blob.core.windows.net/matters/a.eml";
        string b64 = Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(plain));
        int padding = b64.Length - b64.TrimEnd('=').Length;
        string token = b64.TrimEnd('=').Replace('+', '-').Replace('/', '_') + padding;

        Assert.Equal(plain, MattersBlobs.DecodeStoragePath(token));
    }

    [Theory]
    [InlineData("x")]           // too short
    [InlineData("abcd9")]       // padding digit out of range
    public void DecodeStoragePath_rejects_malformed_tokens(string value)
    {
        Assert.Throws<FormatException>(() => MattersBlobs.DecodeStoragePath(value));
    }

    [Fact]
    public void TryResolveBlobName_unescapes_the_name_inside_the_container()
    {
        bool ok = MattersBlobs.TryResolveBlobName(
            "https://samatters.blob.core.windows.net/matters/120.057/Emails/Re%20Hearing.eml",
            out string name, out string error);

        Assert.True(ok, error);
        Assert.Equal("120.057/Emails/Re Hearing.eml", name);
    }

    [Fact]
    public void TryResolveBlobName_refuses_a_path_outside_the_container()
    {
        bool ok = MattersBlobs.TryResolveBlobName(
            "https://samatters.blob.core.windows.net/other/secret.eml",
            out _, out string error);

        Assert.False(ok);
        Assert.Contains("outside the matters container", error);
    }

    [Theory]
    [InlineData("brief.pdf", "application/pdf")]
    [InlineData("notes.TXT", "text/plain")]
    [InlineData("message.eml", "message/rfc822")]
    [InlineData("thing.unknown", "application/octet-stream")]
    public void InferContentType_maps_by_extension(string file, string expected)
    {
        Assert.Equal(expected, MattersBlobs.InferContentType(file));
    }

    [Fact]
    public void SanitizeFileName_strips_quotes_newlines_and_separators()
    {
        Assert.Equal("a_b_c_d_e", MattersBlobs.SanitizeFileName("a\"b\rc\\d/e"));
    }

    [Fact]
    public void ContentDisposition_keeps_an_ascii_fallback_and_a_utf8_name()
    {
        // Accented subjects are common in this corpus and used to throw inside Kestrel.
        string value = MattersBlobs.ContentDisposition("attachment", "Intercambio de Información.eml");

        Assert.Contains("filename=\"Intercambio de Informaci?n.eml\"", value);
        Assert.Contains("filename*=UTF-8''", value);
        Assert.Contains("Informaci%C3%B3n", value);
    }

    [Fact]
    public void ContentDisposition_falls_back_when_nothing_ascii_survives()
    {
        // No extension: even a bare "." is printable ASCII and would survive the
        // fallback check, so a case that actually exercises the "nothing survives"
        // branch must be ASCII-free end to end.
        string value = MattersBlobs.ContentDisposition("inline", "上級");
        Assert.Contains("filename=\"download\"", value);
    }

    [Theory]
    [InlineData("a/b.eml", true)]
    [InlineData("a/b.MSG", true)]
    [InlineData("a/b.pdf", false)]
    public void IsMailBlob_accepts_both_mail_extensions(string name, bool expected)
    {
        Assert.Equal(expected, MattersBlobs.IsMailBlob(name));
    }
}
