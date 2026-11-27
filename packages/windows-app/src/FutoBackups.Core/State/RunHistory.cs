using System.Globalization;
using System.Text.Json.Serialization;

using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.State;

[JsonConverter(typeof(JsonStringEnumConverter<RunKind>))]
public enum RunKind
{
    Backup,
    Restore,
}

public sealed record RunEntry(
    [property: JsonPropertyName("kind")] RunKind Kind,
    [property: JsonPropertyName("status")] BackupStatus Status,
    [property: JsonPropertyName("startedAt")] DateTimeOffset StartedAt,
    [property: JsonPropertyName("finishedAt")] DateTimeOffset FinishedAt,
    [property: JsonPropertyName("message")] string? Message = null,
    [property: JsonPropertyName("supportLog")] string? SupportLog = null,
    [property: JsonPropertyName("supportCode")] string? SupportCode = null)
{
    public TimeSpan Duration => FinishedAt - StartedAt;

    public string Title => (Kind, Status) switch
    {
        (RunKind.Restore, BackupStatus.Complete) => Text.HistoryRestoreComplete,
        (RunKind.Restore, BackupStatus.Cancelled) => Text.ErrorRestoreCancelled,
        (RunKind.Restore, BackupStatus.Failed) => Text.RunRestoreFailed,
        (RunKind.Restore, _) => Text.RunRestoreStoppedEarly,
        (_, BackupStatus.Complete) => Text.RunBackupComplete,
        (_, BackupStatus.Warn) => Text.StatusBackedUpWithWarnings,
        (_, BackupStatus.Failed) => Text.RunBackupFailed,
        (_, BackupStatus.Incomplete) => Text.StatusBackupInterrupted,
        (_, BackupStatus.Skipped) => Text.RunBackupSkipped,
        _ => Text.StatusBackupCancelled,
    };

    public bool Matches(string query) =>
        query.Length == 0
        || Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)
        || (Message?.Contains(query, StringComparison.CurrentCultureIgnoreCase) ?? false)
        || Format.Absolute(StartedAt).Contains(query, StringComparison.CurrentCultureIgnoreCase);
}

public static class RunHistory
{
    public const int Limit = 200;

    public static IReadOnlyList<RunEntry> Adding(IReadOnlyList<RunEntry>? runs, RunEntry entry) =>
        new[] { entry }.Concat(runs ?? []).OrderByDescending(run => run.StartedAt).Take(Limit).ToList();

    public static IReadOnlyList<RunEntry> Filtered(IReadOnlyList<RunEntry>? runs, BackupStatus? status, string query) =>
        (runs ?? []).Where(run => (status is null || run.Status == status) && run.Matches(query.Trim())).ToList();

    public static DateTimeOffset? LastSuccessfulBackup(IReadOnlyList<RunEntry>? runs) =>
        (runs ?? []).FirstOrDefault(run => run.Kind == RunKind.Backup && run.Status is BackupStatus.Complete or BackupStatus.Warn)?.FinishedAt;

    public static string DurationText(TimeSpan duration) => duration.TotalSeconds < 60
        ? string.Format(CultureInfo.CurrentCulture, Text.RunSeconds, Math.Max(0, (int)duration.TotalSeconds))
        : duration.TotalHours >= 1 ? string.Format(CultureInfo.CurrentCulture, Text.RunHoursMinutes, (int)duration.TotalHours, duration.Minutes) : string.Format(CultureInfo.CurrentCulture, Text.RunMinutes, (int)duration.TotalMinutes);
}
