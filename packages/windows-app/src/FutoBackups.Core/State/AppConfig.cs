using System.Globalization;
using System.Text.Json.Serialization;

using FutoBackups.Core.Restic;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.State;

[JsonConverter(typeof(JsonStringEnumConverter<BackupStatus>))]
public enum BackupStatus
{
    Incomplete,
    Complete,
    Warn,
    Failed,
    Cancelled,
    Skipped,
}

public sealed record CloudOnlySkip(
    [property: JsonPropertyName("count")] int Count,
    [property: JsonPropertyName("bytes")] long Bytes,
    [property: JsonPropertyName("sample")] IReadOnlyList<string> Sample)
{
    public const int SampleLimit = 200;

    public string Headline
    {
        get
        {
            var isFolder = Sample.Any(path => path.EndsWith('\\'));
            var sized = Bytes > 0;
            var sentence = (Count == 1, isFolder, sized) switch
            {
                (true, true, true) => Text.StatusCloudOnlyOneItemSized,
                (true, true, false) => Text.StatusCloudOnlyOneItem,
                (true, false, true) => Text.StatusCloudOnlyOneFileSized,
                (true, false, false) => Text.StatusCloudOnlyOneFile,
                (false, true, true) => Text.StatusCloudOnlyItemsSized,
                (false, true, false) => Text.StatusCloudOnlyItems,
                (false, false, true) => Text.StatusCloudOnlyFilesSized,
                (false, false, false) => Text.StatusCloudOnlyFiles,
            };
            return string.Format(CultureInfo.CurrentCulture, sentence, Count, Format.Bytes(Bytes));
        }
    }

    public string ListTitle => Count > Sample.Count ? string.Format(CultureInfo.CurrentCulture, Text.StatusFirstAndMore, Sample.Count, Count - Sample.Count) : string.Format(CultureInfo.CurrentCulture, Text.StatusAllCount, Count);

    public string TelemetrySizeBucket => Bytes switch
    {
        0 => "0",
        < 100_000_000 => "<100MB",
        < 1_000_000_000 => "<1GB",
        < 10_000_000_000 => "<10GB",
        < 100_000_000_000 => "<100GB",
        _ => ">=100GB",
    };
}

public sealed record RunRecord
{
    [JsonPropertyName("startedAt")] public DateTimeOffset StartedAt { get; init; }
    [JsonPropertyName("finishedAt")] public DateTimeOffset FinishedAt { get; init; }
    [JsonPropertyName("status")] public BackupStatus Status { get; init; }
    [JsonPropertyName("snapshotId")] public string? SnapshotId { get; init; }
    [JsonPropertyName("filesNew")] public int? FilesNew { get; init; }
    [JsonPropertyName("dataAdded")] public long? DataAdded { get; init; }
    [JsonPropertyName("filesProcessed")] public int? FilesProcessed { get; init; }
    [JsonPropertyName("bytesProcessed")] public long? BytesProcessed { get; init; }
    [JsonPropertyName("message")] public string? Message { get; init; }
    [JsonPropertyName("cloudOnlySkipped")] public CloudOnlySkip? CloudOnlySkipped { get; init; }
    [JsonPropertyName("warnings")] public BackupWarnings? Warnings { get; init; }

    public BackupWarnings? WarningsForSnapshot(string snapshotId) => SnapshotId == snapshotId ? Warnings : null;
}

public sealed record RememberedRepository(
    [property: JsonPropertyName("id")] string Id,
    [property: JsonPropertyName("lastRun")] RunRecord? LastRun = null,
    [property: JsonPropertyName("scheduleAnchor")] DateTimeOffset? ScheduleAnchor = null,
    [property: JsonPropertyName("failureNotifiedAt")] DateTimeOffset? FailureNotifiedAt = null,
    [property: JsonPropertyName("schedule")] Schedule? Schedule = null);

public sealed record AppConfig
{
    public static readonly Uri ProductionServerUrl = new("https://meta.futo.cloud/.well-known/yucca.json");

    public static readonly Uri DevServerUrl = new("http://localhost:3020/api/meta");

    public static readonly int[] ParallelismChoices = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 128];

    [JsonPropertyName("serverURL")] public Uri ServerUrl { get; init; } = ProductionServerUrl;
    [JsonPropertyName("folders")] public IReadOnlyList<string> Folders { get; init; } = [];
    [JsonPropertyName("excludes")] public IReadOnlyList<string> Excludes { get; init; } = [];
    [JsonPropertyName("schedule")] public Schedule Schedule { get; init; } = Schedule.Daily(12, 0);
    [JsonPropertyName("schedulePaused")] public bool SchedulePaused { get; init; }
    [JsonPropertyName("throttle")] public Throttle Throttle { get; init; } = Throttle.Unthrottled;
    [JsonPropertyName("host")] public string Host { get; init; } = string.Empty;
    [JsonPropertyName("repositoryId")] public string? RepositoryId { get; init; }
    [JsonPropertyName("lastRun")] public RunRecord? LastRun { get; init; }
    [JsonPropertyName("scheduleAnchor")] public DateTimeOffset? ScheduleAnchor { get; init; }
    [JsonPropertyName("recoveryKeyConfirmedAt")] public DateTimeOffset? RecoveryKeyConfirmedAt { get; init; }
    [JsonPropertyName("telemetryConsentedAt")] public DateTimeOffset? TelemetryConsentedAt { get; init; }
    [JsonPropertyName("alphaAcknowledgedAt")] public DateTimeOffset? AlphaAcknowledgedAt { get; init; }
    [JsonPropertyName("onboardingCompletedAt")] public DateTimeOffset? OnboardingCompletedAt { get; init; }
    [JsonPropertyName("excludeDefaultsVersion")] public int? ExcludeDefaultsVersion { get; init; }
    [JsonPropertyName("repositoriesByServer")] public IReadOnlyDictionary<string, RememberedRepository>? RepositoriesByServer { get; init; }
    [JsonPropertyName("uploadConnections")] public int? UploadConnections { get; init; }
    [JsonPropertyName("readConcurrency")] public int? ReadConcurrency { get; init; }
    [JsonPropertyName("retention")] public SnapshotRetention? Retention { get; init; }
    [JsonPropertyName("failureNotifiedAt")] public DateTimeOffset? FailureNotifiedAt { get; init; }
    [JsonPropertyName("failureNotificationsEnabled")] public bool? FailureNotificationsEnabled { get; init; }
    [JsonPropertyName("failureNotificationHintDismissedAt")] public DateTimeOffset? FailureNotificationHintDismissedAt { get; init; }
    [JsonPropertyName("automaticUpdateChecks")] public bool? AutomaticUpdateChecks { get; init; }
    [JsonPropertyName("supportModeRunsRemaining")] public int? SupportModeRunsRemaining { get; init; }
    [JsonPropertyName("supportModeShareWithFuto")] public bool? SupportModeShareWithFuto { get; init; }
    [JsonPropertyName("supportModeIncludesPaths")] public bool? SupportModeIncludesPaths { get; init; }
    [JsonPropertyName("activeRunStartedAt")] public DateTimeOffset? ActiveRunStartedAt { get; init; }
    [JsonPropertyName("runs")] public IReadOnlyList<RunEntry>? Runs { get; init; }
    [JsonPropertyName("conditions")] public BackupConditions? Conditions { get; init; }
    [JsonPropertyName("keepAwake")] public bool? KeepAwake { get; init; }
    [JsonPropertyName("writeOnce")] public bool? WriteOnce { get; init; }
    [JsonPropertyName("waitingForConditionsSince")] public DateTimeOffset? WaitingForConditionsSince { get; init; }

    [JsonIgnore] public SnapshotRetention SnapshotRetention => Retention ?? SnapshotRetention.Standard;

    [JsonIgnore] public BackupConditions BackupConditions => Conditions ?? BackupConditions.None;

    [JsonIgnore] public bool KeepsAwake => KeepAwake ?? true;

    [JsonIgnore] public bool IsWriteOnce => WriteOnce ?? false;

    [JsonIgnore] public DateTimeOffset? ScheduleReference => LastRun?.StartedAt is { } started && ScheduleAnchor is { } anchor ? (started > anchor ? started : anchor) : LastRun?.StartedAt ?? ScheduleAnchor;

    [JsonIgnore] public bool SendsFailureNotifications => FailureNotificationsEnabled ?? true;

    [JsonIgnore] public bool IsProductionServer => ServerUrl == ProductionServerUrl;

    [JsonIgnore]
    public string ServerDisplayName => IsProductionServer
        ? "futo.cloud"
        : ServerUrl.IsDefaultPort ? ServerUrl.Host : $"{ServerUrl.Host}:{ServerUrl.Port}";

    public static AppConfig Defaults(string host, string home) => new()
    {
        Excludes = Exclusions.Defaults(home),
        Host = host,
        ExcludeDefaultsVersion = Exclusions.CurrentDefaultsVersion,
        FailureNotificationsEnabled = true,
        Schedule = Schedule.SpreadDefault(Random.Shared),
    };

    public AppConfig SwitchingServer(Uri url)
    {
        if (url == ServerUrl) return this;
        var remembered = new Dictionary<string, RememberedRepository>(RepositoriesByServer ?? new Dictionary<string, RememberedRepository>());
        if (RepositoryId is { } id)
        {
            remembered[ServerUrl.AbsoluteUri] = new RememberedRepository(id, LastRun, ScheduleAnchor, FailureNotifiedAt, Schedule);
        }
        else
        {
            remembered.Remove(ServerUrl.AbsoluteUri);
        }

        var restored = remembered.GetValueOrDefault(url.AbsoluteUri);
        return this with
        {
            ServerUrl = url,
            RepositoryId = restored?.Id,
            LastRun = restored?.LastRun,
            ScheduleAnchor = restored?.ScheduleAnchor,
            FailureNotifiedAt = restored?.FailureNotifiedAt,
            Schedule = restored?.Schedule ?? Schedule,
            RepositoriesByServer = remembered.Count == 0 ? null : remembered,
        };
    }

    public AppConfig AddingNewDefaultExcludes(string home, out bool changed)
    {
        var seen = ExcludeDefaultsVersion ?? 1;
        changed = seen < Exclusions.CurrentDefaultsVersion;
        if (!changed) return this;
        var excludes = Excludes.ToList();
        foreach (var pattern in Exclusions.DefaultExcludesByVersion.Skip(seen).SelectMany(version => version))
        {
            var expanded = Exclusions.ExpandHome(pattern, home);
            var coversChosenFolder = ExcludePattern.Parse(expanded) is { } parsed && Folders.Any(parsed.Matches);
            if (!excludes.Contains(expanded, StringComparer.OrdinalIgnoreCase) && !coversChosenFolder)
            {
                excludes.Add(expanded);
            }
        }

        return this with { Excludes = excludes, ExcludeDefaultsVersion = Exclusions.CurrentDefaultsVersion };
    }
}
