using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.ResticWrapper;

public sealed class BackupCommandTests : ResticRepository
{
    [Fact]
    public async Task ABackupReportsProgressAndASummaryOfWhatItAdded()
    {
        await InitAsync();
        var folder = Folder(("a.txt", "one"), ("photos/b.jpg", "two"));
        var messages = new List<ResticMessage>();

        var result = await RunAsync(In(ResticCli.Backup()).Host("test-pc").ProgressFps(60).DiscardStdout().AddFile(folder), line => messages.Add(ResticOutput.ParseLine(line)));

        Assert.Equal(ResticExitCode.Success, result.ExitCode);
        Assert.Empty(result.Stdout);
        Assert.Contains(messages, message => message is ResticMessage.Status);
        var summary = Assert.Single(messages.OfType<ResticMessage.Summary>()).Value;
        Assert.Equal(2, summary.FilesNew);
        Assert.NotNull(summary.SnapshotId);
    }

    [Fact]
    public async Task ExcludedPathsAreLeftOutIgnoringCase()
    {
        await InitAsync();
        var folder = Folder(("keep.txt", "keep"), ("node_modules/lib.js", "skip"), ("Cache/blob", "skip"));

        var target = Path.Combine(Root, "restored");

        var result = await RunAsync(In(ResticCli.Backup()).IExclude(@"**\NODE_MODULES", Path.Combine(folder, "cache")).AddFile(folder));
        await RunAsync(In(ResticCli.Restore()).Target(target).Snapshot("latest"));

        Assert.Equal(ResticExitCode.Success, result.ExitCode);
        Assert.Equal(["keep.txt"], Directory.EnumerateFiles(target, "*", SearchOption.AllDirectories).Select(Path.GetFileName));
    }

    [Fact]
    public async Task TheHostAndTagsAreRecordedOnTheSnapshot()
    {
        await InitAsync();

        var snapshot = await BackUpAsync(Folder(("a.txt", "one")), "office-pc", "scheduled", "windows");

        Assert.Equal("office-pc", snapshot.Hostname);
        Assert.Equal(["scheduled", "windows"], snapshot.Tags);
    }

    [Fact]
    public async Task AFileThatCannotBeReadEndsWithTheIncompleteSnapshotCode()
    {
        await InitAsync();
        var folder = Folder(("open.db", "locked"), ("fine.txt", "fine"));
        await using var held = new FileStream(Path.Combine(folder, "open.db"), FileMode.Open, FileAccess.ReadWrite, FileShare.None);

        var result = await RunAsync(In(ResticCli.Backup()).AddFile(folder));

        Assert.Equal(ResticExitCode.CouldNotReadSource, result.ExitCode);
        Assert.Contains("open.db", ResticOutput.LastItemError(result.Stderr), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task BackingUpToARepositoryThatDoesNotExistEndsWithItsCode()
    {
        var result = await RunAsync(In(ResticCli.Backup()).AddFile(Folder(("a.txt", "one"))));

        Assert.Equal(ResticExitCode.RepositoryDoesNotExist, result.ExitCode);
    }

    [Fact]
    public async Task AWrongPasswordEndsWithItsCodeAndResticsMessage()
    {
        await InitAsync();

        var result = await RunAsync(In(ResticCli.Backup(), "wrong").AddFile(Folder(("a.txt", "one"))));

        Assert.Equal(ResticExitCode.WrongPassword, result.ExitCode);
        Assert.Contains("password", ResticOutput.LastError(result.Stderr), StringComparison.OrdinalIgnoreCase);
    }
}
