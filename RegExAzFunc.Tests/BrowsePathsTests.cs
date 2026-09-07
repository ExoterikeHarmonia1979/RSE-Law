using Company.Function;

namespace RegExAzFunc.Tests;

public class BrowsePathsTests
{
    [Fact]
    public void TryNormalizePrefix_treats_empty_as_the_container_root()
    {
        Assert.True(BrowsePaths.TryNormalizePrefix(null, out string prefix, out _));
        Assert.Equal("", prefix);

        Assert.True(BrowsePaths.TryNormalizePrefix("", out prefix, out _));
        Assert.Equal("", prefix);
    }

    [Fact]
    public void TryNormalizePrefix_appends_the_trailing_delimiter()
    {
        Assert.True(BrowsePaths.TryNormalizePrefix("120.057/Emails", out string prefix, out _));
        Assert.Equal("120.057/Emails/", prefix);
    }

    [Fact]
    public void TryNormalizePrefix_leaves_an_already_terminated_prefix_alone()
    {
        Assert.True(BrowsePaths.TryNormalizePrefix("120.057/", out string prefix, out _));
        Assert.Equal("120.057/", prefix);
    }

    [Theory]
    [InlineData("/120.057/")]          // absolute
    [InlineData("../secrets/")]        // traversal
    [InlineData("120.057/../../x/")]   // traversal mid-path
    public void TryNormalizePrefix_refuses_paths_that_try_to_escape(string raw)
    {
        Assert.False(BrowsePaths.TryNormalizePrefix(raw, out _, out string error));
        Assert.NotEqual("", error);
    }

    [Theory]
    [InlineData("120.057/Emails/Attachments/kabc/brief.pdf", "attachment")]
    [InlineData("120.057/Emails/Re Hearing [kabc].eml", "eml")]
    [InlineData("120.057/Emails/Re Hearing [kabc].MSG", "msg")]
    [InlineData("120.057/Notes/scan.pdf", "other")]
    public void ClassifyKind_puts_attachments_first_then_falls_back_to_the_extension(string name, string expected)
    {
        Assert.Equal(expected, BrowsePaths.ClassifyKind(name));
    }

    [Fact]
    public void ClassifyKind_matches_the_attachments_segment_case_insensitively()
    {
        Assert.Equal("attachment", BrowsePaths.ClassifyKind("m/Emails/ATTACHMENTS/k1/a.pdf"));
    }

    [Fact]
    public void LeafName_takes_the_last_segment_of_a_blob_or_a_prefix()
    {
        Assert.Equal("brief.pdf", BrowsePaths.LeafName("120.057/Emails/Attachments/k1/brief.pdf"));
        Assert.Equal("Emails", BrowsePaths.LeafName("120.057/Emails/"));
        Assert.Equal("120.057", BrowsePaths.LeafName("120.057/"));
    }

    [Fact]
    public void BlobUrl_escapes_each_segment_but_keeps_the_separators()
    {
        string url = BrowsePaths.BlobUrl("120.057/Emails/Re Hearing.eml");
        Assert.Equal("https://samatters.blob.core.windows.net/matters/120.057/Emails/Re%20Hearing.eml", url);
    }
}
