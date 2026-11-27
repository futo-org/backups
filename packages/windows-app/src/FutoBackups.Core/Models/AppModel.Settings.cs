using System.Globalization;

using FutoBackups.Core.Engine;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;

namespace FutoBackups.Core.Models;

public sealed partial class AppModel
{
    public bool LaunchAtLogin
    {
        get => platform.LaunchAtLogin;
        set
        {
            try
            {
                platform.LaunchAtLogin = value;
            }
            catch (Exception error)
            {
                LastError = string.Format(CultureInfo.CurrentCulture, Text.ErrorCouldNotChangeLaunchAtLogin, error.Message);
            }

            OnPropertyChanged();
        }
    }

    public void AddFolders(IEnumerable<string> paths)
    {
        UpdateConfig(config =>
        {
            var folders = config.Folders.ToList();
            folders.AddRange(paths.Where(path => !folders.Contains(path, StringComparer.OrdinalIgnoreCase)));
            return config with { Folders = folders, ScheduleAnchor = config.ScheduleAnchor ?? DateTimeOffset.Now };
        });
        NotifyOperationChanged();
        ReportRepositoryChange();
    }

    public void RemoveFolder(string path)
    {
        if (Config.Folders.Count <= 1)
        {
            LastError = Text.FoldersKeepOne;
            return;
        }

        UpdateConfig(config => config with { Folders = config.Folders.Where(folder => folder != path).ToList() });
        NotifyOperationChanged();
        ReportRepositoryChange();
    }

    public bool HasAllDefaultExclusions => Exclusions.Defaults(platform.Home).All(pattern => Config.Excludes.Contains(pattern, StringComparer.OrdinalIgnoreCase));

    public bool IsDefaultExclusion(string pattern) => Exclusions.IsDefault(pattern, platform.Home);

    public void AddExcludedPaths(IReadOnlyList<string> paths) => UpdateExclusions(Exclusions.Excluding(paths, Config.Excludes));

    public bool IsExcludedPath(string path) => Exclusions.IsExcluded(path, Config.Excludes);

    public bool CanExcludePath(string path) => !Exclusions.WouldExcludeAnyFolder(path, Config.Folders);

    public string? AddExclusionPattern(string input)
    {
        if (Exclusions.NormalizedPattern(input, platform.Home) is not { } pattern) return Text.ErrorEnterFolderFilePattern;
        try
        {
            UpdateExclusions(Exclusions.Adding([pattern], Config.Excludes));
            return null;
        }
        catch (ExclusionException)
        {
            return Text.ErrorAlreadyExcluded;
        }
    }

    public IReadOnlyList<string> CustomExclusions => Config.Excludes.Where(pattern => !IsDefaultExclusion(pattern)).ToList();

    public IReadOnlyList<string> CustomExclusionsMatching(string query) => Exclusions.Matching(CustomExclusions, query, platform.Home);

    public string ExclusionLabel(string pattern) => Exclusions.Label(pattern, platform.Home);

    public void RemoveExclusion(string pattern) => RemoveExclusions([pattern]);

    public void RemoveExclusions(IReadOnlyCollection<string> patterns) => UpdateExclusions(Config.Excludes.Where(exclude => !patterns.Contains(exclude)).ToList());

    public void RestoreDefaultExclusions() => UpdateExclusions(Exclusions.RestoringDefaults(Config.Excludes, platform.Home));

    private void UpdateExclusions(IReadOnlyList<string> excludes)
    {
        if (excludes.SequenceEqual(Config.Excludes)) return;
        UpdateConfig(config => config with { Excludes = excludes });
        OnPropertyChanged(nameof(HasAllDefaultExclusions));
        Report("Updated exclusions", new() { ["count"] = excludes.Count });
    }

    public void SetSchedule(Schedule schedule)
    {
        if (schedule == Config.Schedule) return;
        UpdateConfig(config => config with { Schedule = schedule, ScheduleAnchor = DateTimeOffset.Now });
        RecomputeNextRun();
        Report("Updated schedule", new() { ["schedule"] = ScheduleDescription(schedule) });
    }

    public void SetSchedulePaused(bool paused)
    {
        if (paused == Config.SchedulePaused) return;
        UpdateConfig(config => config with { SchedulePaused = paused, ScheduleAnchor = paused ? config.ScheduleAnchor : DateTimeOffset.Now });
        RecomputeNextRun();
        Report(paused ? "Paused schedule" : "Resumed schedule");
    }

    public void SetUploadConnections(int? connections)
    {
        if (connections == Config.UploadConnections) return;
        UpdateConfig(config => config with { UploadConnections = connections });
        Report("Updated parallelism", new() { ["uploadConnections"] = connections?.ToString(CultureInfo.InvariantCulture) ?? "auto" });
    }

    public void SetReadConcurrency(int? concurrency)
    {
        if (concurrency == Config.ReadConcurrency) return;
        UpdateConfig(config => config with { ReadConcurrency = concurrency });
        Report("Updated parallelism", new() { ["readConcurrency"] = concurrency?.ToString(CultureInfo.InvariantCulture) ?? "auto" });
    }

    public void SetRetention(SnapshotRetention retention)
    {
        if (retention == Config.SnapshotRetention) return;
        UpdateConfig(config => config with { Retention = retention });
        Report("Updated snapshot retention", new() { ["retentionPolicy"] = retention.TelemetryValue });
    }

    public void SetFailureNotifications(bool enabled)
    {
        if (enabled == Config.SendsFailureNotifications) return;
        UpdateConfig(config => config with { FailureNotificationsEnabled = enabled });
        if (!enabled)
        {
            platform.WithdrawFailureNotifications();
        }
    }

    public void SetBackupConditions(BackupConditions conditions)
    {
        if (conditions == Config.BackupConditions) return;
        UpdateConfig(config => config with { Conditions = conditions });
        Report("Updated backup conditions", new() { ["conditions"] = conditions.Required.Select(condition => condition.TelemetryName).ToArray(), ["runAnywayAfterDays"] = conditions.RunAnywayAfterDays ?? 0 });
        Tick();
    }

    public void SetKeepAwake(bool enabled)
    {
        if (enabled == Config.KeepsAwake) return;
        UpdateConfig(config => config with { KeepAwake = enabled });
        Report("Updated keep awake", new() { ["enabled"] = enabled });
    }

    public async Task<string?> RenameRepositoryAsync(string name)
    {
        var trimmed = name.Trim();
        if (trimmed.Length == 0) return Text.SettingsBackupNameRequired;
        return await UpdateThisRepositoryAsync(trimmed, null);
    }

    public async Task<string?> EnableWriteOnceAsync()
    {
        var error = await UpdateThisRepositoryAsync(null, true);
        if (error is null)
        {
            UpdateConfig(config => config with { WriteOnce = true });
        }

        return error;
    }

    public async Task<string?> DisableWriteOnceAsync()
    {
        if (Config.RepositoryId is not { } repositoryId || sessionToken is null) return Text.CommonNotSignedIn;
        try
        {
            var client = await account.ClientAsync(Config.ServerUrl, sessionToken);
            var url = await client.CreateTicketAsync(TicketActions.DisableWriteOnce, repositoryId);
            await platform.OpenAsync(url);
            WaitingForWriteOnceOff = true;
            _ = WatchWriteOnceOffAsync();
            return null;
        }
        catch (Exception error)
        {
            return Message(error) ?? error.Message;
        }
    }

    private async Task WatchWriteOnceOffAsync()
    {
        for (var attempt = 0; attempt < 120 && WaitingForWriteOnceOff; attempt++)
        {
            await Task.Delay(TimeSpan.FromSeconds(5));
            await RefreshStorageAsync();
        }

        WaitingForWriteOnceOff = false;
    }

    private async Task<string?> UpdateThisRepositoryAsync(string? name, bool? writeOnce)
    {
        if (Config.RepositoryId is not { } repositoryId || sessionToken is null) return Text.CommonNotSignedIn;
        try
        {
            var client = await account.ClientAsync(Config.ServerUrl, sessionToken);
            ThisRepository = await client.UpdateRepositoryAsync(repositoryId, name, writeOnce);
            Report("Updated repository", new() { ["repositoryId"] = repositoryId });
            return null;
        }
        catch (Exception error)
        {
            return Message(error) ?? error.Message;
        }
    }

    public bool AllowsBackgroundUpdateChecks => Config.OnboardingCompletedAt is not null && Config.AutomaticUpdateChecks == true;

    public void SetAutomaticUpdateChecks(bool enabled) => UpdateConfig(config => config with { AutomaticUpdateChecks = enabled });

    public void GrantTelemetryConsent()
    {
        UpdateConfig(config => config with { TelemetryConsentedAt = DateTimeOffset.Now });
        Report("Telemetry consent granted");
    }

    public void AcknowledgeAlpha() => UpdateConfig(config => config with { AlphaAcknowledgedAt = DateTimeOffset.Now });

    public void SetThrottle(Throttle throttle)
    {
        if (throttle == Config.Throttle) return;
        UpdateConfig(config => config with { Throttle = throttle });
        if (engine is not null)
        {
            _ = engine.UpdateThrottleAsync(throttle);
        }
    }

    public void SetServerUrl(Uri url)
    {
        if (url == Config.ServerUrl) return;
        Logout();
        platform.WithdrawFailureNotifications();
        UpdateConfig(config => config.SwitchingServer(url));
        RecomputeNextRun();
    }

    public const int MaxSupportRuns = 20;

    public void SetSupportMode(int runs, bool shareWithFuto, bool includePaths)
    {
        UpdateConfig(config => config with { SupportModeRunsRemaining = runs > 0 ? Math.Min(runs, MaxSupportRuns) : null, SupportModeShareWithFuto = runs > 0 ? shareWithFuto : null, SupportModeIncludesPaths = runs > 0 ? includePaths : null });
        Report(runs > 0 ? "Turned on support mode" : "Turned off support mode", new() { ["runs"] = runs }, force: runs > 0 && shareWithFuto);
    }

    private static string ScheduleDescription(Schedule schedule) => schedule.Kind switch
    {
        ScheduleKind.Manual => "manual",
        ScheduleKind.Hourly => "hourly",
        ScheduleKind.Daily => $"daily {schedule.Hour:00}:{schedule.Minute:00}",
        ScheduleKind.Custom => $"custom {schedule.Cron}",
        _ => $"weekly {schedule.Weekday.ToString().ToLowerInvariant()} {schedule.Hour:00}:{schedule.Minute:00}",
    };
}
