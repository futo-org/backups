using System.Globalization;
using System.Text.Json;

using FutoBackups.Core.State;

namespace FutoBackups.Core.Tests.State;

public class RunHistoryTests
{
    private static readonly DateTimeOffset Noon = DateTimeOffset.Parse("2026-11-25T12:00:00Z", CultureInfo.InvariantCulture);

    private static RunEntry Run(int minutesAgo, BackupStatus status, RunKind kind = RunKind.Backup, string? message = null) =>
        new(kind, status, Noon.AddMinutes(-minutesAgo), Noon.AddMinutes(-minutesAgo + 3), message);

    [Fact]
    public void RunsAreKeptNewestFirstAndCappedAtTheLimit()
    {
        IReadOnlyList<RunEntry> runs = [];
        for (var index = RunHistory.Limit + 5; index > 0; index--) runs = RunHistory.Adding(runs, Run(index, BackupStatus.Complete));
        runs = RunHistory.Adding(runs, Run(500, BackupStatus.Failed));

        Assert.Equal(RunHistory.Limit, runs.Count);
        Assert.Equal(Noon.AddMinutes(-1), runs[0].StartedAt);
        Assert.DoesNotContain(runs, run => run.Status == BackupStatus.Failed);
    }

    [Fact]
    public void FilteringByResultIncludesCancelledAndInterruptedRuns()
    {
        IReadOnlyList<RunEntry> runs = [Run(1, BackupStatus.Complete), Run(2, BackupStatus.Cancelled), Run(3, BackupStatus.Incomplete), Run(4, BackupStatus.Complete, RunKind.Restore)];

        Assert.Single(RunHistory.Filtered(runs, BackupStatus.Cancelled, ""));
        Assert.Equal("Backup interrupted", Assert.Single(RunHistory.Filtered(runs, BackupStatus.Incomplete, "")).Title);
        Assert.Equal(4, RunHistory.Filtered(runs, null, "").Count);
    }

    [Fact]
    public void SearchMatchesTheTitleAndTheMessage()
    {
        IReadOnlyList<RunEntry> runs = [Run(1, BackupStatus.Failed, message: "Could not connect to futo.cloud."), Run(2, BackupStatus.Complete, RunKind.Restore)];

        Assert.Equal(BackupStatus.Failed, Assert.Single(RunHistory.Filtered(runs, null, "CONNECT")).Status);
        Assert.Equal(RunKind.Restore, Assert.Single(RunHistory.Filtered(runs, null, "restore")).Kind);
    }

    [Fact]
    public void ARunSurvivesTheConfigFileRoundTrip()
    {
        var config = new AppConfig { Runs = [Run(5, BackupStatus.Warn, message: "2 files")] };
        var read = JsonSerializer.Deserialize<AppConfig>(JsonSerializer.Serialize(config, ConfigStore.JsonOptions), ConfigStore.JsonOptions)!;

        Assert.Equal(config.Runs, read.Runs);
        Assert.Equal(TimeSpan.FromMinutes(3), read.Runs![0].Duration);
    }

    [Theory]
    [InlineData(BackupStatus.Complete, "Restore complete")]
    [InlineData(BackupStatus.Cancelled, "Restore cancelled")]
    [InlineData(BackupStatus.Incomplete, "Restore stopped early")]
    [InlineData(BackupStatus.Failed, "Restore failed")]
    public void EveryRestoreResultHasItsOwnTitle(BackupStatus status, string title) =>
        Assert.Equal(title, Run(1, status, RunKind.Restore).Title);

    [Fact]
    public void TheLastSuccessfulBackupSkipsFailedCancelledAndRestoreRuns()
    {
        IReadOnlyList<RunEntry> runs = [Run(1, BackupStatus.Failed), Run(2, BackupStatus.Complete, RunKind.Restore), Run(3, BackupStatus.Cancelled), Run(4, BackupStatus.Warn), Run(5, BackupStatus.Complete)];

        Assert.Equal(Noon.AddMinutes(-4 + 3), RunHistory.LastSuccessfulBackup(runs));
        Assert.Null(RunHistory.LastSuccessfulBackup([Run(1, BackupStatus.Failed)]));
    }
}
