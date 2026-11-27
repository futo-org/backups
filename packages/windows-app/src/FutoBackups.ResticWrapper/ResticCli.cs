namespace FutoBackups.ResticWrapper;

public static class ResticCli
{
    public static SimpleCommand Version() => new("version");

    public static SimpleCommand Init() => new("init");

    public static SimpleCommand Unlock() => new("unlock");

    public static BackupCommand Backup() => new();

    public static SimpleCommand Snapshots() => new("snapshots");

    public static ForgetCommand Forget() => new();

    public static RestoreCommand Restore() => new();

    public static LsCommand Ls() => new();

    public static StatsCommand Stats() => new();

    public static SimpleCommand CatConfig() => new("cat", "config");

    public static SimpleCommand KeyList() => new("key", "list");

    public static KeyAddCommand KeyAdd() => new();

    public static KeyRemoveCommand KeyRemove() => new();
}

public sealed class SimpleCommand(params string[] command) : ResticCommandBuilder<SimpleCommand>(command);

public sealed class BackupCommand() : ResticCommandBuilder<BackupCommand>("backup")
{
    public BackupCommand Host(string host) => Flag("--host", host);

    public BackupCommand GroupBy(string grouping) => Flag("--group-by", grouping);

    public BackupCommand ExcludeCaches() => Flag("--exclude-caches");

    public BackupCommand ExcludeCloudFiles() => Flag("--exclude-cloud-files");

    public BackupCommand Tag(params IEnumerable<string> tags) => Repeated("--tag", tags);

    public BackupCommand IExclude(params IEnumerable<string> patterns) => Repeated("--iexclude", patterns);

    public BackupCommand WalkConcurrency(int? workers) => Flag("--walk-concurrency", workers);

    public BackupCommand ReadConcurrency(int? workers) => Flag("--read-concurrency", workers);

    public BackupCommand AddFile(params IEnumerable<string> paths) => Positional(paths);
}

public sealed class ForgetCommand() : ResticCommandBuilder<ForgetCommand>("forget")
{
    public ForgetCommand Host(string host) => Flag("--host", host);

    public ForgetCommand GroupBy(string grouping) => Flag("--group-by", grouping);

    public ForgetCommand KeepLast(int count) => Flag("--keep-last", count);

    public ForgetCommand KeepWithin(string duration) => Flag("--keep-within", duration);

    public ForgetCommand KeepWithinHourly(string duration) => Flag("--keep-within-hourly", duration);

    public ForgetCommand KeepWithinDaily(string duration) => Flag("--keep-within-daily", duration);

    public ForgetCommand KeepWithinWeekly(string duration) => Flag("--keep-within-weekly", duration);

    public ForgetCommand KeepWithinMonthly(string duration) => Flag("--keep-within-monthly", duration);

    public ForgetCommand KeepWithinYearly(string duration) => Flag("--keep-within-yearly", duration);

    public ForgetCommand Prune() => Flag("--prune");
}

public sealed class RestoreCommand() : ResticCommandBuilder<RestoreCommand>("restore")
{
    public static string LiteralPattern(string name) =>
        "/" + string.Concat(name.Select(character => character is '[' or '*' or '?' ? $"[{character}]" : character.ToString()));

    public RestoreCommand Snapshot(string snapshotId, string? subfolder = null) => Positional(subfolder is null ? snapshotId : $"{snapshotId}:{subfolder}");

    public RestoreCommand Target(string directory) => Flag("--target", directory);

    public RestoreCommand Overwrite(string behaviour) => Flag("--overwrite", behaviour);

    public RestoreCommand IncludeLiteral(params IEnumerable<string> names) => Repeated("--include", names.Select(LiteralPattern));
}

public sealed class LsCommand() : ResticCommandBuilder<LsCommand>("ls")
{
    public LsCommand Snapshot(string snapshotId, string directory) => Positional(snapshotId, directory);
}

public sealed class StatsCommand() : ResticCommandBuilder<StatsCommand>("stats")
{
    public StatsCommand Mode(string mode) => Flag("--mode", mode);
}

public sealed class KeyAddCommand() : ResticCommandBuilder<KeyAddCommand>("key", "add")
{
    public KeyAddCommand NewPasswordFile(string path) => Flag("--new-password-file", path);
}

public sealed class KeyRemoveCommand() : ResticCommandBuilder<KeyRemoveCommand>("key", "remove")
{
    public KeyRemoveCommand Key(string id) => Positional(id);
}
