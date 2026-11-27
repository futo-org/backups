using System.Globalization;

using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Restic;

public sealed record ResticContext(
    string Repository,
    string Password,
    string CacheDirectory,
    int Connections,
    int? PackSizeMiB = null,
    int? WalkConcurrency = null,
    int? ReadConcurrency = null)
{
    public const int MinPackSizeMiB = 4;
    public const int MaxPackSizeMiB = 128;
}

public static class ResticCommand
{
    private const int ProgressFramesPerSecond = 2;

    public static ResticInvocation Version() => ResticCli.Version().ToInvocation();

    public static ResticInvocation Initialize(ResticContext context) => ResticCli.Init().In(context).ToInvocation();

    public static ResticInvocation Unlock(ResticContext context) => ResticCli.Unlock().In(context).ToInvocation();

    public static ResticInvocation Backup(ResticContext context, IReadOnlyList<string> paths, IReadOnlyList<string> excludes, string host, IReadOnlyList<string>? tags = null) =>
        ResticCli.Backup().In(context)
            .Host(host).GroupBy("host").ExcludeCaches().ExcludeCloudFiles()
            .Tag(tags ?? []).IExclude(excludes)
            .PackSize(context.PackSizeMiB).WalkConcurrency(context.WalkConcurrency).ReadConcurrency(context.ReadConcurrency)
            .ProgressFps(ProgressFramesPerSecond).DiscardStdout()
            .AddFile(paths)
            .ToInvocation();

    public static ResticInvocation Snapshots(ResticContext context) => ResticCli.Snapshots().In(context).NoLock().ToInvocation();

    public static ResticInvocation? Forget(ResticContext context, string host, SnapshotRetention retention)
    {
        if (retention.PrunablePolicy is not { } policy) return null;
        var forget = ResticCli.Forget().In(context).Host(host).GroupBy("host");
        return policy.ApplyTo(forget).Prune().PackSize(context.PackSizeMiB).ToInvocation();
    }

    public static ResticInvocation Restore(ResticContext context, string snapshotId, string target, string? subfolder = null, IReadOnlyList<string>? children = null) =>
        ResticCli.Restore().In(context)
            .Target(target).Overwrite("never").IncludeLiteral(children ?? [])
            .ProgressFps(ProgressFramesPerSecond).DiscardStdout()
            .Snapshot(snapshotId, subfolder)
            .ToInvocation();

    public static ResticInvocation Ls(ResticContext context, string snapshotId, string directory) =>
        ResticCli.Ls().In(context).NoLock().Snapshot(snapshotId, directory).ToInvocation();

    public static ResticInvocation Stats(ResticContext context) => ResticCli.Stats().In(context).Mode("raw-data").ToInvocation();

    public static ResticInvocation CatConfig(ResticContext context) => ResticCli.CatConfig().In(context).ToInvocation();

    public static ResticInvocation KeyList(ResticContext context) => ResticCli.KeyList().In(context).ToInvocation();

    public static ResticInvocation KeyAdd(ResticContext context, string newPasswordFile) =>
        ResticCli.KeyAdd().In(context).NewPasswordFile(newPasswordFile).ToInvocation();

    public static ResticInvocation KeyRemove(ResticContext context, string id) => ResticCli.KeyRemove().In(context).Key(id).ToInvocation();

    public static string FailureMessage(ResticResult result) =>
        ResticOutput.LastError(result.Stderr) ?? string.Format(CultureInfo.CurrentCulture, Text.ErrorResticExited, result.ExitCode);

    private static T In<T>(this T command, ResticContext context) where T : ResticCommandBuilder<T> =>
        command.Repository(context.Repository).Password(context.Password)
            .Option($"rest.connections={context.Connections}").CacheDir(context.CacheDirectory);
}
