using System.Text.Json;

using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.ResticWrapper;

public sealed class RepositoryCommandTests : ResticRepository
{
    [Fact]
    public async Task VersionNamesTheResticBuild()
    {
        var result = await RunAsync(ResticCli.Version());

        Assert.Matches(@"^\d+\.\d+\.\d+", ResticOutput.ParseVersion(result.Stdout));
    }

    [Fact]
    public async Task AnInitialisedRepositoryHasAConfigWithItsId()
    {
        await InitAsync();

        var result = await RunAsync(In(ResticCli.CatConfig()));

        Assert.Equal(ResticExitCode.Success, result.ExitCode);
        Assert.False(string.IsNullOrEmpty(JsonElement.Parse(result.Stdout).GetProperty("id").GetString()));
    }

    [Fact]
    public async Task InitialisingTwiceFails()
    {
        await InitAsync();

        var result = await RunAsync(In(ResticCli.Init()));

        Assert.NotEqual(ResticExitCode.Success, result.ExitCode);
    }

    [Fact]
    public async Task OpeningARepositoryThatDoesNotExistEndsWithItsCode()
    {
        var result = await RunAsync(In(ResticCli.Snapshots()));

        Assert.Equal(ResticExitCode.RepositoryDoesNotExist, result.ExitCode);
    }

    [Fact]
    public async Task UnlockRemovesStaleLocks()
    {
        await InitAsync();

        var result = await RunAsync(In(ResticCli.Unlock()));

        Assert.Equal(ResticExitCode.Success, result.ExitCode);
    }

    [Fact]
    public async Task StatsReportTheStoredSize()
    {
        await InitAsync();
        await BackUpAsync(Folder(("a.txt", new string('x', 10_000))));

        var result = await RunAsync(In(ResticCli.Stats()).Mode("raw-data"));

        Assert.True(ResticOutput.ParseStatsTotalSize(result.Stdout) > 0);
    }

    [Fact]
    public async Task AnAddedKeyOpensTheRepositoryUntilItIsRemoved()
    {
        await InitAsync();
        var newPassword = Path.Combine(Root, "new-password");
        await File.WriteAllTextAsync(newPassword, "second-password", TestContext.Current.CancellationToken);

        var added = await RunAsync(In(ResticCli.KeyAdd()).NewPasswordFile(newPassword));
        var listed = await RunAsync(In(ResticCli.KeyList()));
        var keys = ResticOutput.ParseKeys(listed.Stdout);
        var openedWithNewKey = await RunAsync(In(ResticCli.CatConfig(), "second-password"));
        var removed = await RunAsync(In(ResticCli.KeyRemove()).Key(keys.Single(key => !key.Current).Id));
        var openedAfterRemoval = await RunAsync(In(ResticCli.CatConfig(), "second-password"));

        Assert.Equal(ResticExitCode.Success, added.ExitCode);
        Assert.Equal(2, keys.Count);
        Assert.Equal(ResticExitCode.Success, openedWithNewKey.ExitCode);
        Assert.Equal(ResticExitCode.Success, removed.ExitCode);
        Assert.Equal(ResticExitCode.WrongPassword, openedAfterRemoval.ExitCode);
    }

    [Fact]
    public async Task ForgetKeepsOnlyWhatTheRulesKeepForEachHost()
    {
        await InitAsync();
        var folder = Folder(("a.txt", "one"));
        for (var run = 0; run < 3; run++)
        {
            await File.WriteAllTextAsync(Path.Combine(folder, "a.txt"), $"run {run}", TestContext.Current.CancellationToken);
            await BackUpAsync(folder);
        }

        await BackUpAsync(folder, "other-pc");

        var result = await RunAsync(In(ResticCli.Forget()).Host("test-pc").GroupBy("host").KeepLast(1).Prune());
        var listed = await RunAsync(In(ResticCli.Snapshots()));
        var snapshots = ResticOutput.ParseSnapshots(listed.Stdout);

        Assert.Equal(ResticExitCode.Success, result.ExitCode);
        Assert.Equal(["other-pc", "test-pc"], snapshots.Select(snapshot => snapshot.Hostname).Order());
    }
}
