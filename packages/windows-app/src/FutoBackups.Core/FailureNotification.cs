using System.Globalization;

using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core;

public enum BackupFailureReason
{
    Unreachable,
    SignedOut,
    MissingRecoveryKey,
    Other,
}

public static class BackupFailureReasons
{
    public static BackupFailureReason From(Exception error) => error switch
    {
        EngineException { Error: EngineError.NotLoggedIn } or YuccaApiException { StatusCode: 401 } => BackupFailureReason.SignedOut,
        EngineException { Error: EngineError.MissingMasterKey } => BackupFailureReason.MissingRecoveryKey,
        _ when ConnectionFailures.From(error) is not null => BackupFailureReason.Unreachable,
        EngineException { Error: EngineError.Restic } restic => FromMessage(restic.ResticMessage),
        _ => FromMessage(error.Message),
    };

    public static BackupFailureReason FromMessage(string? message)
    {
        if (message is null) return BackupFailureReason.Other;
        if (message == ErrorMessage.SessionExpired || message.Contains(ConnectionFailures.RejectedCredentialsPhrase)) return BackupFailureReason.SignedOut;
        if (message == Text.ErrorNotSignedIn) return BackupFailureReason.SignedOut;
        if (message == Text.ErrorMissingKey) return BackupFailureReason.MissingRecoveryKey;
        if (Enum.GetValues<ConnectionFailure>().Any(failure => failure.IsProducedBy(message))) return BackupFailureReason.Unreachable;
        return ConnectionFailures.FromRestic(message) is not null ? BackupFailureReason.Unreachable : BackupFailureReason.Other;
    }
}

public abstract record BackupRunOutcome
{
    public sealed record Succeeded : BackupRunOutcome;

    public sealed record Failed(BackupFailureReason Reason) : BackupRunOutcome;

    public sealed record Stopped : BackupRunOutcome;

    public static BackupRunOutcome From(RunRecord record) => record.Status switch
    {
        BackupStatus.Complete or BackupStatus.Warn => new Succeeded(),
        BackupStatus.Failed => new Failed(BackupFailureReasons.FromMessage(record.Message)),
        _ => new Stopped(),
    };

    public static BackupRunOutcome From(Exception error) =>
        error is OperationCanceledException ? new Stopped() : new Failed(BackupFailureReasons.From(error));
}

public abstract record FailureNoticeStep
{
    public sealed record Nothing : FailureNoticeStep;

    public sealed record Post(BackupFailureReason Reason) : FailureNoticeStep;

    public sealed record EndStreak : FailureNoticeStep;

    public static FailureNoticeStep After(BackupRunOutcome outcome, bool scheduled, bool notifies, bool streakNotified, bool noticePending) => outcome switch
    {
        BackupRunOutcome.Succeeded when streakNotified || noticePending => new EndStreak(),
        BackupRunOutcome.Failed failed when scheduled && notifies && !streakNotified && !noticePending => new Post(failed.Reason),
        _ => new Nothing(),
    };
}

public sealed record FailureNotice(string Title, string Body)
{
    public static string DefaultTitle => Text.NotificationDefaultTitle;

    public static FailureNotice For(BackupFailureReason reason, string server, DateTimeOffset? retryAt, DateTimeOffset now)
    {
        var retry = retryAt is { } at ? RetrySentence(at, now) : null;
        var body = reason switch
        {
            BackupFailureReason.Unreachable => Join(string.Format(CultureInfo.CurrentCulture, Text.NotificationCouldNotConnect, server), retry),
            BackupFailureReason.SignedOut => Text.NotificationSignedOut,
            BackupFailureReason.MissingRecoveryKey => Text.NotificationMissingKey,
            _ => Join(Text.NotificationStopped, retry),
        };
        return new FailureNotice(DefaultTitle, body);
    }

    private static string Join(string first, string? second) => second is null ? first : $"{first} {second}";

    public static string RetrySentence(DateTimeOffset at, DateTimeOffset now)
    {
        if (at <= now) return Text.NotificationRetrySoon;
        var local = at.ToLocalTime();
        var time = local.ToString("t", Format.Culture);
        var today = now.ToLocalTime().Date;
        if (local.Date == today) return string.Format(CultureInfo.CurrentCulture, Text.NotificationRetryAt, time);
        if (local.Date == today.AddDays(1)) return string.Format(CultureInfo.CurrentCulture, Text.NotificationRetryTomorrowAt, time);
        return string.Format(CultureInfo.CurrentCulture, Text.NotificationRetryOnAt, local.ToString("dddd", Format.Culture), time);
    }
}

public static class FailureNotificationConfig
{
    public static string ServerName(this AppConfig config) => config.IsProductionServer ? Text.CommonFutoCloud : config.ServerDisplayName;

    public static bool ShowsFailureNotificationHint(this AppConfig config, bool notificationsOn) =>
        config.Schedule.Kind != ScheduleKind.Manual && !notificationsOn && config.FailureNotificationHintDismissedAt is null;
}
