using FutoBackups.Core.State;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.Tests.State;

public class ExclusionsTests
{
    private const string Home = @"C:\Users\test";

    [Fact]
    public void DefaultsExpandTheHomeFolder()
    {
        var defaults = Exclusions.Defaults(Home);
        Assert.Contains(@"C:\Users\test\AppData\Local\Temp", defaults);
        Assert.Contains(@"**\node_modules", defaults);
        Assert.True(Exclusions.IsDefault(@"C:\Users\test\AppData\Local\CrashDumps", Home));
        Assert.False(Exclusions.IsDefault(@"C:\Users\test\Videos", Home));
    }

    [Fact]
    public void PickedPathsWithBracketsMatchOnlyTheLiteralPath()
    {
        var pattern = Exclusions.PatternForPath(@"C:\Users\test\Old [2019]");
        Assert.Equal(@"C:\Users\test\Old [[]2019]", pattern);
        Assert.True(ExcludePattern.Parse(pattern)!.Matches(@"C:\Users\test\Old [2019]\a.txt"));
        Assert.False(ExcludePattern.Parse(pattern)!.Matches(@"C:\Users\test\Old 2"));
    }

    [Theory]
    [InlineData("  *.iso  ", "*.iso")]
    [InlineData(@"~\Downloads\Old", @"C:\Users\test\Downloads\Old")]
    [InlineData(@"~\Downloads\Old\", @"C:\Users\test\Downloads\Old")]
    [InlineData("~", @"C:\Users\test")]
    [InlineData(@"**\build", @"**\build")]
    [InlineData(@"C:\", @"C:\")]
    public void TypedPatternsAreTrimmedAndExpandTheHomeFolder(string input, string expected) =>
        Assert.Equal(expected, Exclusions.NormalizedPattern(input, Home));

    [Fact]
    public void BlankPatternsAreRejected() => Assert.Null(Exclusions.NormalizedPattern("   ", Home));

    [Fact]
    public void AddingKeepsOrderAndRejectsDuplicates()
    {
        string[] start = [@"**\node_modules"];
        Assert.Equal([@"**\node_modules", "*.iso", @"**\build"], Exclusions.Adding(["*.iso", "*.iso", @"**\build"], start));
        Assert.Equal(ExclusionError.AlreadyExcluded, Assert.Throws<ExclusionException>(() => Exclusions.Adding([@"**\node_modules"], start)).Error);
        Assert.Equal(ExclusionError.Empty, Assert.Throws<ExclusionException>(() => Exclusions.Adding([], start)).Error);
    }

    [Fact]
    public void RestoringDefaultsPutsMissingOnesBackFirst()
    {
        string[] custom = ["*.iso", @"C:\Users\test\AppData\Local\Temp"];
        var restored = Exclusions.RestoringDefaults(custom, Home);
        Assert.Equal(Exclusions.Defaults(Home).Length + 1, restored.Count);
        Assert.Equal(custom, restored[^2..]);
    }

    [Theory]
    [InlineData(new[] { @"C:\Users\test\Videos" }, true)]
    [InlineData(new[] { @"C:\Users\test\Videos", @"!C:\Users\test\Videos" }, false)]
    [InlineData(new[] { @"C:\Users\test\Videos", @"!C:\Users\test\Vid*" }, false)]
    [InlineData(new[] { @"!C:\Users\test\Videos", @"C:\Users\test\Videos" }, true)]
    [InlineData(new[] { @"C:\Users\test\Videos", @"!C:\Users\test\Music" }, true)]
    [InlineData(new[] { @"C:\Users\test\Vid*", @"!C:\Users\test\Videos" }, false)]
    [InlineData(new[] { @"C:\Users\test" }, true)]
    [InlineData(new[] { "Videos" }, true)]
    [InlineData(new[] { @"C:\Users\test\Music" }, false)]
    [InlineData(new string[0], false)]
    public void TheLastMatchingPatternDecidesAsInRestic(string[] excludes, bool expected) =>
        Assert.Equal(expected, Exclusions.IsExcluded(@"C:\Users\test\Videos", excludes));

    [Fact]
    public void ExcludingMovesAnOverriddenPathAfterItsNegation()
    {
        Assert.Equal(
            [@"!C:\Users\test\Vid*", "*.iso", @"C:\Users\test\Videos"],
            Exclusions.Excluding([@"C:\Users\test\Videos"], [@"C:\Users\test\Videos", @"!C:\Users\test\Vid*", "*.iso"]));
        Assert.Equal([@"C:\Users\test\Vid*"], Exclusions.Excluding([@"C:\Users\test\Videos"], [@"C:\Users\test\Vid*"]));
    }

    [Theory]
    [InlineData(@"C:\Users\test\Documents", new[] { @"C:\Users\test\Documents" }, true)]
    [InlineData(@"C:\Users\test\Documents", new[] { @"C:\Users\test\Documents\Taxes" }, true)]
    [InlineData(@"C:\", new[] { @"C:\Users\test" }, true)]
    [InlineData(@"C:\Users\test\Old [1]", new[] { @"C:\Users\test\Old [1]\Photos" }, true)]
    [InlineData(@"C:\Users\test\Documents\a.txt", new[] { @"C:\Users\test\Documents" }, false)]
    [InlineData(@"C:\Users\test\Doc", new[] { @"C:\Users\test\Documents" }, false)]
    [InlineData(@"C:\Users\test\Documents", new string[0], false)]
    public void ExcludingAPathIsRefusedWhenItWouldCoverAChosenFolder(string path, string[] folders, bool expected) =>
        Assert.Equal(expected, Exclusions.WouldExcludeAnyFolder(path, folders));

    [Theory]
    [InlineData(@"**\node_modules", "node_modules")]
    [InlineData(@"C:\Users\test\Videos\[[]old]", @"~\Videos\[old]")]
    [InlineData(@"D:\Scratch", @"D:\Scratch")]
    [InlineData("*.iso", "*.iso")]
    public void AnExclusionIsLabelledTheWayTheUserWouldTypeIt(string pattern, string label) =>
        Assert.Equal(label, Exclusions.Label(pattern, Home));

    [Fact]
    public void SearchingExclusionsMatchesThePatternOrItsLabelIgnoringCase()
    {
        string[] patterns = [@"C:\Users\test\Downloads\Old", @"**\node_modules", "*.iso"];

        Assert.Equal([@"C:\Users\test\Downloads\Old"], Exclusions.Matching(patterns, @"~\down", Home));
        Assert.Equal([@"**\node_modules"], Exclusions.Matching(patterns, " NODE ", Home));
        Assert.Equal(patterns, Exclusions.Matching(patterns, "  ", Home));
    }
}
