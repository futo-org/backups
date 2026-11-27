using FutoBackups.Core.Util;

namespace FutoBackups.Core.Tests.Util;

public class ExcludePatternTests
{
    [Theory]
    [InlineData("*.go", @"C:\foo\bar\test.go", true)]
    [InlineData("*.go", @"C:\foo\bar\test.go.bak", false)]
    [InlineData("bar", @"C:\foo\bar\test.go", true)]
    [InlineData(@"C:\foo", @"C:\foo\bar\test.go", true)]
    [InlineData(@"C:\foo\bar", @"C:\foo", false)]
    [InlineData(@"D:\foo", @"C:\foo\bar", false)]
    [InlineData(@"foo\bar", @"C:\x\foo\bar\y", true)]
    [InlineData("foo/bar", @"C:\x\foo\bar\y", true)]
    [InlineData(@"**\node_modules", @"C:\a\b\node_modules", true)]
    [InlineData(@"**\node_modules", @"C:\a\node_modules_old", false)]
    [InlineData(@"foo\**\bar", @"C:\x\foo\a\b\bar", true)]
    [InlineData(@"foo\**\bar", @"C:\x\foo\a\b\baz", false)]
    [InlineData(@"C:\Users\x\AppData\Local\Packages\*\LocalCache", @"C:\Users\x\AppData\Local\Packages\App.1\LocalCache", true)]
    [InlineData(@"C:\Users\x\AppData\Local\Packages\*\LocalCache", @"C:\Users\x\AppData\Local\Packages\App.1", false)]
    [InlineData(@"C:\Users\x\AppData\Local\Temp", @"C:\Users\x\AppData\Local\TempOld", false)]
    [InlineData("[a-c]at", @"C:\x\bat", true)]
    [InlineData("[^a-c]at", @"C:\x\bat", false)]
    [InlineData("ca?", @"C:\x\cat", true)]
    [InlineData(@"**\$Recycle.Bin", @"C:\$RECYCLE.BIN", true)]
    [InlineData(@"C:\Users\X\DOCUMENTS", @"c:\users\x\Documents\a.txt", true)]
    [InlineData(@"C:\foo\..\bar\", @"C:\bar\x", true)]
    public void MatchesLikeResticsCaseInsensitiveWindowsExcludeFilter(string pattern, string path, bool expected) =>
        Assert.Equal(expected, ExcludePattern.Parse(pattern)!.Matches(path));

    [Theory]
    [InlineData("")]
    [InlineData("!keep")]
    [InlineData("[")]
    [InlineData("[]a]")]
    [InlineData("[z-a]")]
    public void RejectsPatternsResticWouldNotExclude(string pattern) => Assert.Null(ExcludePattern.Parse(pattern));
}
