using System.Globalization;

using FutoBackups.Core.Engine;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Status;

public enum StatusTint
{
    Accent,
    Success,
    Caution,
    Critical,
    Neutral,
}

public enum StatusAction
{
    BackUp,
    TryAgain,
    AddFolders,
    Cancel,
    SignIn,
    EnterRecoveryKey,
    None,
}

public enum ActivityPhase
{
    Preparing,
    BackingUp,
    Finishing,
    Pruning,
    Restoring,
    ChangingRecoveryKey,
}

public enum StatusIcon
{
    Check,
    Cross,
    Warning,
    Upload,
    Download,
    Search,
    Pause,
    Key,
    Folder,
    Delete,
    Person,
}

public sealed record StatusInput(
    ActivityPhase? Activity,
    bool IsCancelling,
    BackupProgress? Progress,
    RestoreStep? Restore,
    IReadOnlyList<string> Folders,
    RunRecord? LastRun,
    bool SchedulePaused,
    bool SignedOut,
    bool MissingRecoveryKey,
    string ProtectedText,
    string? AttentionMessage = null,
    bool MissingOnService = false,
    string? MissingHelper = null,
    DateTimeOffset? NextRun = null);

public sealed record StatusSummary(
    string Title,
    string Subtitle,
    StatusIcon Icon,
    StatusTint Tint,
    StatusAction Action,
    double? Progress = null,
    bool Busy = false,
    bool NeedsAttention = false)
{
    public static StatusSummary For(StatusInput input)
    {
        if (input.IsCancelling && input.Activity is not null) return new(Text.StatusCancelling, Text.StatusStoppingSafely, StatusIcon.Cross, StatusTint.Accent, StatusAction.None, Busy: true);
        switch (input.Activity)
        {
            case ActivityPhase.BackingUp when (input.Progress?.PercentDone ?? 0) >= 0.999:
                return new(Text.StatusFinishingBackup, Text.StatusUploadingLastChanges, StatusIcon.Upload, StatusTint.Accent, StatusAction.Cancel, Busy: true);
            case ActivityPhase.BackingUp:
                return new(Text.StatusBackingUp, input.Progress is { } progress ? Transferred(progress) : string.Empty, StatusIcon.Upload, StatusTint.Accent, StatusAction.Cancel, input.Progress?.PercentDone ?? 0);
            case ActivityPhase.Preparing:
                return new(Text.StatusPreparingBackup, Text.StatusLookingForChanges, StatusIcon.Search, StatusTint.Accent, StatusAction.Cancel, Busy: true);
            case ActivityPhase.Finishing:
                return new(Text.StatusFinishingBackup, Text.StatusLookingForCloudOnly, StatusIcon.Check, StatusTint.Accent, StatusAction.None, Busy: true);
            case ActivityPhase.Pruning:
                return new(Text.StatusTidyingUp, Text.StatusRemovingOldSnapshots, StatusIcon.Delete, StatusTint.Accent, StatusAction.None, Busy: true);
            case ActivityPhase.Restoring:
                var fraction = input.Restore?.Fraction;
                return new(input.Restore?.Title ?? Text.StatusRestoring, input.Restore?.Subtitle() ?? Text.StatusBringingFilesBack, StatusIcon.Download, StatusTint.Accent, StatusAction.Cancel, fraction, fraction is null);
            case ActivityPhase.ChangingRecoveryKey:
                return new(Text.StatusChangingRecoveryKey, Text.StatusUpdatingKey, StatusIcon.Key, StatusTint.Accent, StatusAction.None, Busy: true);
        }

        if (input.MissingHelper is { } missingHelper)
        {
            return new(Text.StatusCannotBackUp, missingHelper, StatusIcon.Cross, StatusTint.Critical, StatusAction.None, NeedsAttention: true);
        }

        if (input.SignedOut)
        {
            return new(Text.StatusSignedOut, Text.StatusSignedOutSubtitle, StatusIcon.Person, StatusTint.Critical, StatusAction.SignIn, NeedsAttention: true);
        }

        if (input.MissingRecoveryKey)
        {
            return new(Text.KeyMissingTitle, Text.KeyMissingSubtitle, StatusIcon.Key, StatusTint.Critical, StatusAction.EnterRecoveryKey, NeedsAttention: true);
        }

        if (input.MissingOnService)
        {
            return new(Text.StatusBackupMissing, Text.StatusBackupMissingSubtitle, StatusIcon.Cross, StatusTint.Critical, StatusAction.None, NeedsAttention: true);
        }

        if (input.Folders.Count == 0)
        {
            return new(Text.CommonChooseWhatToBackUp, Text.StatusAddFolders, StatusIcon.Folder, StatusTint.Accent, StatusAction.AddFolders, NeedsAttention: true);
        }

        if (input.LastRun is not { } lastRun)
        {
            var count = input.Folders.Count;
            return new(Text.StatusReadyForFirstBackup, string.Format(CultureInfo.CurrentCulture, count == 1 ? Text.StatusOneFolderSelected : Text.StatusFoldersSelected, count), StatusIcon.Upload, StatusTint.Accent, StatusAction.BackUp);
        }

        var when = Format.Relative(lastRun.FinishedAt, true);
        var offline = lastRun.Message is { } reason && Enum.GetValues<ConnectionFailure>().Any(failure => failure != ConnectionFailure.Insecure && failure.IsProducedBy(reason));
        var failedSubtitle = string.Format(CultureInfo.CurrentCulture, Text.StatusLastBackupFailedSubtitle, lastRun.Message ?? Text.StatusCheckConnection, when);
        if (offline && !input.SchedulePaused && input.NextRun is { } next)
        {
            failedSubtitle = $"{failedSubtitle} {FailureNotice.RetrySentence(next, DateTimeOffset.Now)}";
        }

        var summary = lastRun.Status switch
        {
            BackupStatus.Complete => new StatusSummary(Text.StatusProtected, string.Format(CultureInfo.CurrentCulture, Text.StatusLastBackupProtected, when, input.ProtectedText), StatusIcon.Check, StatusTint.Success, StatusAction.BackUp),
            BackupStatus.Warn => new StatusSummary(Text.StatusBackedUpWithWarnings, lastRun.Message ?? Text.StatusCouldNotReadSome, StatusIcon.Warning, StatusTint.Caution, StatusAction.BackUp, NeedsAttention: true),
            BackupStatus.Failed => new StatusSummary(offline ? Text.StatusOffline : Text.StatusLastBackupFailed, failedSubtitle, StatusIcon.Cross, StatusTint.Critical, StatusAction.TryAgain, NeedsAttention: true),
            BackupStatus.Incomplete => new StatusSummary(Text.StatusBackupInterrupted, string.Format(CultureInfo.CurrentCulture, Text.StatusBackupInterruptedSubtitle, when), StatusIcon.Pause, StatusTint.Caution, StatusAction.BackUp, NeedsAttention: true),
            _ => new StatusSummary(Text.StatusBackupCancelled, string.Format(CultureInfo.CurrentCulture, Text.StatusStoppedAt, when), StatusIcon.Pause, StatusTint.Neutral, StatusAction.BackUp),
        };
        if (input.SchedulePaused && lastRun.Status is BackupStatus.Complete or BackupStatus.Cancelled)
        {
            return summary with { Title = Text.StatusSchedulePaused, Subtitle = string.Format(CultureInfo.CurrentCulture, Text.StatusSchedulePausedSubtitle, when), Icon = StatusIcon.Pause, Tint = StatusTint.Caution };
        }

        return summary;
    }

    private static string Transferred(BackupProgress progress)
    {
        var parts = new List<string> { string.Format(CultureInfo.CurrentCulture, Text.StatusTransferred, Format.Bytes(progress.BytesDone), Format.Bytes(progress.TotalBytes)) };
        if (progress.SecondsRemaining is { } seconds)
        {
            parts.Add(Format.Duration(seconds));
        }

        return string.Join(" · ", parts);
    }
}

public static class ActivityPhases
{
    public static ActivityPhase Phase(this EngineActivity activity) => activity switch
    {
        EngineActivity.Preparing => ActivityPhase.Preparing,
        EngineActivity.BackingUp => ActivityPhase.BackingUp,
        EngineActivity.Finishing => ActivityPhase.Finishing,
        EngineActivity.Pruning => ActivityPhase.Pruning,
        EngineActivity.Restoring => ActivityPhase.Restoring,
        _ => ActivityPhase.ChangingRecoveryKey,
    };

    public static bool IsCancellable(this ActivityPhase phase) => phase != ActivityPhase.ChangingRecoveryKey;
}
