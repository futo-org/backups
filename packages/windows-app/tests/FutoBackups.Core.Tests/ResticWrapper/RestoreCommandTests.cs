using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.ResticWrapper;

public sealed class RestoreCommandTests : ResticRepository
{
    private static string TreePath(string localPath) => "/" + localPath[0] + localPath[2..].Replace('\\', '/');

    [Fact]
    public async Task ASubfolderRestoresWithoutTheFoldersAboveIt()
    {
        await InitAsync();
        var folder = Folder(("photos/a.jpg", "a"), ("docs/b.txt", "b"));
        var snapshot = await BackUpAsync(folder);
        var target = Path.Combine(Root, "restored");

        var result = await RunAsync(In(ResticCli.Restore()).Target(target).Snapshot(snapshot.Id, TreePath(Path.Combine(folder, "photos"))));

        Assert.Equal(ResticExitCode.Success, result.ExitCode);
        Assert.Equal("a", await File.ReadAllTextAsync(Path.Combine(target, "a.jpg"), TestContext.Current.CancellationToken));
        Assert.False(Directory.Exists(Path.Combine(target, "docs")));
    }

    [Fact]
    public async Task NamedChildrenRestoreLiterallyEvenWithBrackets()
    {
        await InitAsync();
        var folder = Folder(("Holiday [2026].jpg", "picked"), ("Holiday 2.jpg", "not picked"), ("[draft] notes.txt", "picked"), ("d notes.txt", "not picked"));
        var snapshot = await BackUpAsync(folder);
        var target = Path.Combine(Root, "restored");

        await RunAsync(In(ResticCli.Restore()).Target(target).IncludeLiteral("Holiday [2026].jpg", "[draft] notes.txt").Snapshot(snapshot.Id, TreePath(folder)));

        Assert.Equal(["Holiday [2026].jpg", "[draft] notes.txt"], Directory.EnumerateFiles(target).Select(Path.GetFileName).Order(StringComparer.Ordinal));
    }

    [Fact]
    public async Task OverwriteNeverKeepsAFileAlreadyAtTheTarget()
    {
        await InitAsync();
        var folder = Folder(("a.txt", "from the backup"));
        var snapshot = await BackUpAsync(folder);
        var target = Path.Combine(Root, "restored");
        Directory.CreateDirectory(target);
        await File.WriteAllTextAsync(Path.Combine(target, "a.txt"), "already here", TestContext.Current.CancellationToken);

        await RunAsync(In(ResticCli.Restore()).Target(target).Overwrite("never").Snapshot(snapshot.Id, TreePath(folder)));

        Assert.Equal("already here", await File.ReadAllTextAsync(Path.Combine(target, "a.txt"), TestContext.Current.CancellationToken));
    }

    [Fact]
    public async Task ListingAFolderReturnsItsEntriesAsJsonLines()
    {
        await InitAsync();
        var folder = Folder(("a.txt", "one"), ("sub/b.txt", "two"));
        var snapshot = await BackUpAsync(folder);

        var result = await RunAsync(In(ResticCli.Ls()).Snapshot(snapshot.Id, TreePath(folder)));

        Assert.Equal(ResticExitCode.Success, result.ExitCode);
        Assert.Contains("\"name\":\"a.txt\"", result.Stdout, StringComparison.Ordinal);
        Assert.Contains("\"name\":\"sub\"", result.Stdout, StringComparison.Ordinal);
    }
}
