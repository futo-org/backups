using System.Runtime.InteropServices;

using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.ResticWrapper;

public abstract class ResticRepository : IDisposable
{
    public const string Password = "test-password";

    protected ResticRepository()
    {
        var arch = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        var executable = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "build", "helpers", arch, "restic.exe"));
        Assert.SkipUnless(File.Exists(executable), "Build the test project to build restic first.");
        Runner = new ResticRunner(executable);
        Location = Path.Combine(Root, "repo");
    }

    protected string Root { get; } = Directory.CreateTempSubdirectory("futo-restic-wrapper-").FullName;

    protected string Location { get; }

    protected ResticRunner Runner { get; }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Root, true);
        }
        catch (IOException)
        {
        }

        GC.SuppressFinalize(this);
    }

    protected T In<T>(T command, string password = Password) where T : ResticCommandBuilder<T> =>
        command.Repository(Location).Password(password).CacheDir(Path.Combine(Root, "cache"));

    protected async Task<ResticResult> RunAsync<T>(T command, Action<string>? onLine = null) where T : ResticCommandBuilder<T> =>
        await Runner.RunAsync(command.ToInvocation(), onLine, TestContext.Current.CancellationToken);

    protected async Task InitAsync()
    {
        var result = await RunAsync(In(ResticCli.Init()));
        Assert.Equal(ResticExitCode.Success, result.ExitCode);
    }

    protected string Folder(params (string Path, string Content)[] files)
    {
        var folder = Path.Combine(Root, "Source Folder");
        foreach (var (path, content) in files)
        {
            var full = Path.Combine(folder, path);
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllText(full, content);
        }

        return folder;
    }

    protected async Task<Snapshot> BackUpAsync(string folder, string host = "test-pc", params string[] tags)
    {
        var result = await RunAsync(In(ResticCli.Backup()).Host(host).Tag(tags).AddFile(folder));
        Assert.Equal(ResticExitCode.Success, result.ExitCode);
        var snapshots = await RunAsync(In(ResticCli.Snapshots()));
        return ResticOutput.ParseSnapshots(snapshots.Stdout).OrderByDescending(snapshot => snapshot.Time).First();
    }
}
