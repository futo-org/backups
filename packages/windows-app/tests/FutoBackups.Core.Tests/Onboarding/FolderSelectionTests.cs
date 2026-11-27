using FutoBackups.Core.Onboarding;
using FutoBackups.Core.State;

namespace FutoBackups.Core.Tests.Onboarding;

public class FolderSelectionTests
{
    private const string Home = @"C:\Users\test";

    private sealed class KnownFolders : IKnownFolders
    {
        public string Home => FolderSelectionTests.Home;

        public string PathOf(StandardFolder folder) => $@"{Home}\{folder}";
    }

    private static FolderSelection Selection(FolderBundle bundle = FolderBundle.EssentialsAndMedia, params string[] missing) =>
        new(new KnownFolders(), bundle, path => !missing.Contains(path));

    [Fact]
    public void EssentialsAndMediaSelectsTheMediaFoldersButNotDownloads() =>
        Assert.Equal([$@"{Home}\Documents", $@"{Home}\Desktop", $@"{Home}\Pictures", $@"{Home}\Videos", $@"{Home}\Music"], Selection().Paths);

    [Fact]
    public void FoldersThatDoNotExistAreNotOffered()
    {
        var selection = Selection(FolderBundle.Essentials, $@"{Home}\Desktop");

        Assert.DoesNotContain(new FolderChoice.Standard(StandardFolder.Desktop), selection.Choices);
        Assert.Equal([$@"{Home}\Documents"], selection.Paths);
    }

    [Fact]
    public void EverythingBacksUpTheUserFolderAloneAndCoversTheRest()
    {
        var selection = Selection(FolderBundle.Everything);
        var documents = new FolderChoice.Standard(StandardFolder.Documents);

        selection.Set(documents, true);

        Assert.Equal([Home], selection.Paths);
        Assert.Equal(new FolderChoice.Home(), selection.CoveringChoice(documents));
        Assert.True(selection.IsIncluded(new FolderChoice.Standard(StandardFolder.Downloads)));
    }

    [Fact]
    public void AnAddedKnownFolderSelectsItInsteadOfAddingItTwice()
    {
        var selection = Selection(FolderBundle.Essentials);
        var count = selection.Choices.Count;

        selection.AddOthers([$@"{Home}\downloads", @"D:\Projects"]);

        Assert.Equal(count + 1, selection.Choices.Count);
        Assert.True(selection.IsSelected(new FolderChoice.Standard(StandardFolder.Downloads)));
        Assert.Contains(@"D:\Projects", selection.Paths);
    }

    [Fact]
    public void ChangingTheBundleKeepsAddedFolders()
    {
        var selection = Selection();
        selection.AddOthers([@"D:\Projects"]);

        selection.Apply(FolderBundle.Essentials);

        Assert.Equal([$@"{Home}\Documents", $@"{Home}\Desktop", @"D:\Projects"], selection.Paths);
    }

    [Fact]
    public void NothingSelectedCannotContinue()
    {
        var selection = Selection(FolderBundle.Essentials);

        selection.Set(new FolderChoice.Standard(StandardFolder.Documents), false);
        selection.Set(new FolderChoice.Standard(StandardFolder.Desktop), false);

        Assert.False(selection.CanContinue);
    }

    [Theory]
    [InlineData(@"C:\Users\test", @"C:\Users\test\Documents", true)]
    [InlineData(@"C:\", @"C:\Users", true)]
    [InlineData(@"C:\Users\test", @"C:\Users\testing", false)]
    [InlineData(@"C:\Users\test", @"C:\Users\test", false)]
    public void AnAncestorMustContainThePathNotJustStartLikeIt(string ancestor, string path, bool expected) =>
        Assert.Equal(expected, FolderSelection.IsAncestor(ancestor, path));

    [Fact]
    public void ATotalWithAnUnreadableFolderIsAtLeastTheSum()
    {
        Assert.Equal(new FolderSize.AtLeast(30).Text, FolderSizer.TotalText([new FolderSize.Bytes(10), new FolderSize.AtLeast(20)]));
        Assert.Equal(new FolderSize.Calculating().Text, FolderSizer.TotalText([new FolderSize.Bytes(10), new FolderSize.Calculating()]));
    }

    [Fact]
    public void CompletingOnboardingAddsTheChosenFoldersOnce()
    {
        var date = new DateTimeOffset(2026, 11, 27, 12, 0, 0, TimeSpan.Zero);
        var config = AppConfig.Defaults("pc", Home) with { Folders = [$@"{Home}\Documents"] };

        var completed = config.CompletingOnboarding([$@"{Home}\documents", @"D:\Projects"], date);

        Assert.Equal([$@"{Home}\Documents", @"D:\Projects"], completed.Folders);
        Assert.Equal(date, completed.OnboardingCompletedAt);
        Assert.Equal(date, completed.ScheduleAnchor);
        Assert.False(completed.NeedsOnboarding());
    }
}
