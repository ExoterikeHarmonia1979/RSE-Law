using System.Text;

namespace RegExAzFunc.Tests;

/// <summary>
/// Windows-1252 must be resolvable, or MsgReader throws
/// "No data is available for encoding 1252" on any .msg carrying legacy-codepage content.
///
/// This is a regression test for a bug that reached production twice. The registration was
/// originally placed in EmlAttachmentNamesSkill's static initialiser so the skill could not
/// ship without it; that stopped being sufficient once MsgProjection and DedupToken also
/// used MsgReader, because a static initialiser only runs when its own class is touched.
/// Seven of forty real .msg blobs failed conformance before it moved to Program.cs.
///
/// The test registers the provider itself rather than depending on Program.cs, because the
/// unit-test host never runs Program.cs. What it pins is the weaker but still useful claim
/// that the provider is available to register and does resolve 1252 - if the package or the
/// framework assembly ever goes missing, this fails at build or here rather than at runtime
/// on a client's mail.
/// </summary>
public class CodePageRegistrationTests
{
    [Fact]
    public void Windows1252_is_resolvable_once_the_provider_is_registered()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);

        Encoding cp1252 = Encoding.GetEncoding(1252);

        Assert.Equal(1252, cp1252.CodePage);
        // 0x93/0x94 are the curly quotes that exist in 1252 and not in Latin-1 - decoding
        // them proves the real code page is present, not a silent fallback.
        Assert.Equal("“hi”", cp1252.GetString(new byte[] { 0x93, 0x68, 0x69, 0x94 }));
    }
}
