using System.Globalization;
using System.Runtime.InteropServices;

using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.Restic;

public sealed class ResticIntegrationTests : IDisposable
{
    private readonly string root = Directory.CreateTempSubdirectory("futo-restic-").FullName;
    private readonly ResticRunner runner;
    private readonly ResticContext context;

    public ResticIntegrationTests()
    {
        var arch = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        var executable = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "build", "helpers", arch, "restic.exe"));
        Assert.SkipUnless(File.Exists(executable), "Build the test project to build restic first.");
        runner = new ResticRunner(executable);
        context = new ResticContext(Path.Combine(root, "repo"), "test-password", Path.Combine(root, "cache"), 2);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(root, true);
        }
        catch (IOException)
        {
        }
    }

    private string Source(params (string Path, string Content)[] files)
    {
        var source = Path.Combine(root, "Source Folder");
        foreach (var (path, content) in files)
        {
            var full = Path.Combine(source, path);
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllText(full, content);
        }

        return source;
    }

    private async Task<ResticResult> Run(ResticInvocation invocation, Action<string>? onLine = null) =>
        await runner.RunAsync(invocation, onLine, TestContext.Current.CancellationToken);

    [Fact]
    public async Task BackupListsAndRestoresWindowsPathsThroughTheTreePathForm()
    {
        var source = Source(("Notes.txt", "hello"), (@"Photos\Holiday [2026].jpg", "jpg"), (@"Cache\skip.tmp", "tmp"), (@"node_modules\x.js", "js"));
        var initialized = await Run(ResticCommand.Initialize(context));
        Assert.Equal(ResticExitCode.Success, initialized.ExitCode);

        var progress = new List<ResticMessage>();
        var backup = await Run(ResticCommand.Backup(context, [source], [@"**\NODE_MODULES", Path.Combine(source, "cache")], "test-pc"), line => progress.Add(ResticOutput.ParseLine(line)));
        Assert.Equal(ResticExitCode.Success, backup.ExitCode);
        var summary = Assert.Single(progress.OfType<ResticMessage.Summary>()).Value;
        Assert.Equal(2, summary.TotalFilesProcessed);

        var snapshotsResult = await Run(ResticCommand.Snapshots(context));
        var snapshots = ResticOutput.ParseSnapshots(snapshotsResult.Stdout);
        var snapshot = Assert.Single(snapshots);
        Assert.Equal("test-pc", snapshot.Hostname);
        var treeRoot = ResticTreePath.FromLocal(source);
        Assert.Equal(treeRoot, Assert.Single(SnapshotListing.Roots(snapshot.Paths)).Path);

        var listResult = await Run(ResticCommand.Ls(context, snapshot.Id, treeRoot));
        var listing = SnapshotListing.Parse(listResult.Stdout, treeRoot);
        Assert.Equal(["Photos", "Notes.txt"], listing.Select(entry => entry.Name));
        Assert.True(listing[0].IsDirectory);

        var whole = Path.Combine(root, "Restore all");
        var restored = await Run(ResticCommand.Restore(context, snapshot.Id, whole, treeRoot));
        Assert.Equal(ResticExitCode.Success, restored.ExitCode);
        Assert.Equal("hello", File.ReadAllText(Path.Combine(whole, "Notes.txt")));
        Assert.True(File.Exists(Path.Combine(whole, "Photos", "Holiday [2026].jpg")));

        var photos = treeRoot + "/Photos";
        var picked = Path.Combine(root, "Restore picked");
        var pickedResult = await Run(ResticCommand.Restore(context, snapshot.Id, picked, photos, ["Holiday [2026].jpg"]));
        Assert.True(pickedResult.ExitCode == ResticExitCode.Success, pickedResult.Stderr);
        Assert.Equal("jpg", File.ReadAllText(Path.Combine(picked, "Holiday [2026].jpg")));
    }

    [Fact]
    public async Task RestoreNeverOverwritesAnExistingFile()
    {
        var source = Source(("a.txt", "from backup"));
        await Run(ResticCommand.Initialize(context));
        await Run(ResticCommand.Backup(context, [source], [], "test-pc"));
        var snapshotsResult = await Run(ResticCommand.Snapshots(context));
        var snapshot = ResticOutput.ParseSnapshots(snapshotsResult.Stdout)[0];
        var target = Directory.CreateDirectory(Path.Combine(root, "Existing")).FullName;
        File.WriteAllText(Path.Combine(target, "a.txt"), "mine");
        await Run(ResticCommand.Restore(context, snapshot.Id, target, ResticTreePath.FromLocal(source)));
        Assert.Equal("mine", File.ReadAllText(Path.Combine(target, "a.txt")));
    }

    [Fact]
    public async Task ForgetKeepsOnlyWhatTheRetentionPolicyKeepsForThisHost()
    {
        var source = Source(("a.txt", "1"));
        await Run(ResticCommand.Initialize(context));
        for (var index = 0; index < 3; index++)
        {
            File.WriteAllText(Path.Combine(source, "a.txt"), index.ToString(CultureInfo.InvariantCulture));
            await Run(ResticCommand.Backup(context, [source], [], "test-pc"));
        }

        await Run(ResticCommand.Backup(context, [source], [], "other-pc"));
        var forget = ResticCommand.Forget(context, "test-pc", RetentionPreset.LatestTwo.Retention())!;
        var forgotten = await Run(forget);
        Assert.Equal(ResticExitCode.Success, forgotten.ExitCode);
        var snapshotsResult = await Run(ResticCommand.Snapshots(context));
        var hosts = ResticOutput.ParseSnapshots(snapshotsResult.Stdout).Select(snapshot => snapshot.Hostname).Order().ToList();
        Assert.Equal(["other-pc", "test-pc", "test-pc"], hosts);
    }
}
