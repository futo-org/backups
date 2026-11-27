using FutoBackups.Core;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Status;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.Status;

public class StatusSummaryTests
{
    private static StatusInput Input(ActivityPhase? activity = null, RunRecord? lastRun = null, bool paused = false, bool signedOut = false, bool missingKey = false, string[]? folders = null, bool cancelling = false, BackupProgress? progress = null) =>
        new(activity, cancelling, progress, null, folders ?? [@"C:\Users\test\Documents"], lastRun, paused, signedOut, missingKey, "48 GB");

    private static RunRecord Run(BackupStatus status, string? message = null) =>
        new() { StartedAt = DateTimeOffset.Now.AddMinutes(-20), FinishedAt = DateTimeOffset.Now.AddMinutes(-10), Status = status, Message = message };

    [Theory]
    [InlineData(BackupStatus.Complete, "Your files are protected", StatusTint.Success, false, StatusAction.BackUp)]
    [InlineData(BackupStatus.Warn, "Backed up with warnings", StatusTint.Caution, true, StatusAction.BackUp)]
    [InlineData(BackupStatus.Failed, "Last backup failed", StatusTint.Critical, true, StatusAction.TryAgain)]
    [InlineData(BackupStatus.Incomplete, "Backup interrupted", StatusTint.Caution, true, StatusAction.BackUp)]
    [InlineData(BackupStatus.Cancelled, "Backup cancelled", StatusTint.Neutral, false, StatusAction.BackUp)]
    public void EveryResultHasItsOwnStateAndMarksTheOnesThatNeedTheUser(BackupStatus status, string title, StatusTint tint, bool attention, StatusAction action)
    {
        var summary = StatusSummary.For(Input(lastRun: Run(status)));
        Assert.Equal(title, summary.Title);
        Assert.Equal(tint, summary.Tint);
        Assert.Equal(attention, summary.NeedsAttention);
        Assert.Equal(action, summary.Action);
    }

    [Fact]
    public void TheIconFollowsWhatIsHappening()
    {
        Assert.Equal(StatusIcon.Check, StatusSummary.For(Input(lastRun: Run(BackupStatus.Complete))).Icon);
        Assert.Equal(StatusIcon.Cross, StatusSummary.For(Input(lastRun: Run(BackupStatus.Failed))).Icon);
        Assert.Equal(StatusIcon.Upload, StatusSummary.For(Input(ActivityPhase.BackingUp)).Icon);
        Assert.Equal(StatusIcon.Person, StatusSummary.For(Input(signedOut: true)).Icon);
        Assert.Equal(StatusIcon.Pause, StatusSummary.For(Input(lastRun: Run(BackupStatus.Complete), paused: true)).Icon);
    }

    [Fact]
    public void AFailureKeepsTheTimeOfTheLastAttemptAndSaysExistingBackupsDidNotChange()
    {
        var subtitle = StatusSummary.For(Input(lastRun: Run(BackupStatus.Failed, "Could not connect to futo.cloud."))).Subtitle;
        Assert.StartsWith("Could not connect to futo.cloud.", subtitle);
        Assert.Contains("existing backups did not change", subtitle);
        Assert.Contains("Last attempt ", subtitle);
    }

    [Fact]
    public void FailuresAndWarningsTakePrecedenceOverPaused()
    {
        Assert.Equal("Last backup failed", StatusSummary.For(Input(lastRun: Run(BackupStatus.Failed), paused: true)).Title);
        Assert.Equal("Backed up with warnings", StatusSummary.For(Input(lastRun: Run(BackupStatus.Warn), paused: true)).Title);
        Assert.Equal("Scheduled backups are paused", StatusSummary.For(Input(lastRun: Run(BackupStatus.Complete), paused: true)).Title);
    }

    [Fact]
    public void SignedOutAndMissingKeyOfferTheirFixInPlace()
    {
        Assert.Equal(StatusAction.SignIn, StatusSummary.For(Input(lastRun: Run(BackupStatus.Complete), signedOut: true)).Action);
        Assert.Equal(StatusAction.EnterRecoveryKey, StatusSummary.For(Input(lastRun: Run(BackupStatus.Complete), missingKey: true)).Action);
    }

    [Fact]
    public void NotSetUpAndNeverBackedUpAreDistinct()
    {
        Assert.Equal(StatusAction.AddFolders, StatusSummary.For(Input(folders: [])).Action);
        Assert.Equal("Ready for your first backup", StatusSummary.For(Input()).Title);
    }

    [Fact]
    public void ABackupInProgressShowsProgressAndCanBeCancelled()
    {
        var summary = StatusSummary.For(Input(ActivityPhase.BackingUp, progress: new BackupProgress(0.42, 10, 4, 1_000_000_000, 420_000_000, 125)));
        Assert.Equal(0.42, summary.Progress);
        Assert.Equal(StatusAction.Cancel, summary.Action);
        Assert.Equal("420 MB of 1 GB · 2 min left", summary.Subtitle);
        Assert.Equal("Cancelling", StatusSummary.For(Input(ActivityPhase.BackingUp, cancelling: true)).Title);
        Assert.Equal(StatusAction.None, StatusSummary.For(Input(ActivityPhase.Pruning)).Action);
    }

    [Fact]
    public void ABackupMissingFromTheServiceIsNotCalledProtected()
    {
        var summary = StatusSummary.For(Input(lastRun: Run(BackupStatus.Complete)) with { MissingOnService = true });

        Assert.Equal("This PC's backup is missing", summary.Title);
        Assert.True(summary.NeedsAttention);
    }

    [Fact]
    public void AMissingHelperIsShownInsteadOfBackUpNow()
    {
        var summary = StatusSummary.For(Input(lastRun: Run(BackupStatus.Complete)) with { MissingHelper = "restic.exe is missing from FUTO Backups. Reinstall FUTO Backups to fix it." });

        Assert.Equal("FUTO Backups cannot back up", summary.Title);
        Assert.StartsWith("restic.exe is missing", summary.Subtitle);
        Assert.Equal(StatusAction.None, summary.Action);
        Assert.True(summary.NeedsAttention);
    }

    [Theory]
    [InlineData(ConnectionFailure.Unreachable)]
    [InlineData(ConnectionFailure.Unavailable)]
    [InlineData(ConnectionFailure.Offline)]
    public void AFailureToReachTheServerIsShownAsOffline(ConnectionFailure failure)
    {
        var summary = StatusSummary.For(Input(lastRun: Run(BackupStatus.Failed, failure.Message("futo.cloud"))));

        Assert.Equal("Backups are offline", summary.Title);
        Assert.Equal(StatusAction.TryAgain, summary.Action);
        Assert.True(summary.NeedsAttention);
    }

    [Fact]
    public void AnOfflineFailureSaysWhenItWillTryAgain()
    {
        var next = DateTimeOffset.Now.AddHours(1);
        var subtitle = StatusSummary.For(Input(lastRun: Run(BackupStatus.Failed, ConnectionFailure.Unreachable.Message("futo.cloud"))) with { NextRun = next }).Subtitle;

        Assert.EndsWith(FailureNotice.RetrySentence(next, DateTimeOffset.Now), subtitle);
    }

    [Fact]
    public void AFailureThatIsNotAboutTheConnectionDoesNotPromiseARetryTime()
    {
        var subtitle = StatusSummary.For(Input(lastRun: Run(BackupStatus.Failed, "Disk full")) with { NextRun = DateTimeOffset.Now.AddHours(1) }).Subtitle;

        Assert.DoesNotContain("try again", subtitle);
    }
}
