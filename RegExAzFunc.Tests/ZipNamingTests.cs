using Company.Function;

namespace RegExAzFunc.Tests;

public class ZipNamingTests
{
    [Fact]
    public void EntryName_is_relative_to_the_requested_folder()
    {
        Assert.Equal(
            "Emails/Re Hearing.eml",
            ZipNaming.EntryName("120.057/", "120.057/Emails/Re Hearing.eml"));
    }

    [Fact]
    public void EntryName_keeps_the_attachment_folders_so_the_zip_mirrors_the_archive()
    {
        Assert.Equal(
            "Emails/Attachments/k1/brief.pdf",
            ZipNaming.EntryName("120.057/", "120.057/Emails/Attachments/k1/brief.pdf"));
    }

    [Fact]
    public void EntryName_at_the_container_root_keeps_the_whole_path()
    {
        Assert.Equal("120.057/Emails/a.eml", ZipNaming.EntryName("", "120.057/Emails/a.eml"));
    }

    [Fact]
    public void EntryName_leaves_a_blob_outside_the_prefix_untouched()
    {
        // Defensive: a listing should never produce this, and silently trimming the wrong
        // number of characters would put the file somewhere surprising in the zip.
        Assert.Equal("other/a.eml", ZipNaming.EntryName("120.057/", "other/a.eml"));
    }

    [Fact]
    public void ArchiveFileName_names_the_zip_after_the_folder()
    {
        Assert.Equal("120.057.zip", ZipNaming.ArchiveFileName("120.057/"));
        Assert.Equal("Emails.zip", ZipNaming.ArchiveFileName("120.057/Emails/"));
    }

    [Fact]
    public void ArchiveFileName_falls_back_at_the_container_root()
    {
        Assert.Equal("matters.zip", ZipNaming.ArchiveFileName(""));
    }

    [Fact]
    public void ErrorManifest_lists_what_was_skipped()
    {
        string text = ZipNaming.ErrorManifest(["Emails/a.eml", "Emails/b.eml"]);

        Assert.Contains("2 file(s)", text);
        Assert.Contains("Emails/a.eml", text);
        Assert.Contains("Emails/b.eml", text);
    }
}
