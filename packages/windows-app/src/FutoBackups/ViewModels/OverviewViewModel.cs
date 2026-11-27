using System.Globalization;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core;
using FutoBackups.Core.Models;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Status;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;
using FutoBackups.Pages.Overview;

using Microsoft.UI.Xaml.Media;

namespace FutoBackups.ViewModels;

public sealed record FolderItem(string Path)
{
    public string Name => SnapshotListing.FolderName(Path);

    public string RemoveLabel => string.Format(CultureInfo.CurrentCulture, Text.OverviewStopBackingUp, Path);

    public string RevealLabel => string.Format(CultureInfo.CurrentCulture, Text.OverviewShowInFileExplorer, Path);
}

public sealed partial class OverviewViewModel(AppModel model) : ModelViewModel(model)
{
    private const int PillLimit = 4;

    private static readonly DayOfWeek[] WeekOrder =
        [DayOfWeek.Monday, DayOfWeek.Tuesday, DayOfWeek.Wednesday, DayOfWeek.Thursday, DayOfWeek.Friday, DayOfWeek.Saturday, DayOfWeek.Sunday];

    private Schedule Schedule => Model.Config.Schedule;

    public string[] Weekdays { get; } = WeekOrder.Select(day => CultureInfo.CurrentCulture.DateTimeFormat.GetDayName(day)).ToArray();

    public int ScheduleIndex
    {
        get => (int)Schedule.Kind;
        set
        {
            if (value < 0 || value == ScheduleIndex) return;
            var kind = (ScheduleKind)value;
            Model.SetSchedule(Schedule with { Kind = kind, Cron = kind == ScheduleKind.Custom ? Schedule.Cron ?? Schedule.ExampleCron : Schedule.Cron });
        }
    }

    public int WeekdayIndex
    {
        get => Array.IndexOf(WeekOrder, Schedule.Weekday);
        set
        {
            if (value < 0 || value == WeekdayIndex) return;
            Model.SetSchedule(Schedule with { Weekday = WeekOrder[value] });
        }
    }

    public TimeSpan ScheduleTime
    {
        get => new(Schedule.Hour, Schedule.Minute, 0);
        set
        {
            if (value == ScheduleTime) return;
            Model.SetSchedule(Schedule with { Hour = value.Hours, Minute = value.Minutes });
        }
    }

    public string ScheduleDescription => Schedule.Kind switch
    {
        ScheduleKind.Manual => Text.OverviewScheduleManual,
        ScheduleKind.Hourly => Text.OverviewScheduleHourly,
        ScheduleKind.Daily => Text.OverviewScheduleDaily,
        ScheduleKind.Custom => Text.OverviewScheduleCustom,
        _ => string.Format(CultureInfo.CurrentCulture, Text.OverviewScheduleWeekly, Weekdays[WeekdayIndex]),
    };

    public bool ShowsTime => Schedule.Kind is ScheduleKind.Daily or ScheduleKind.Weekly;

    public bool ShowsCron => Schedule.Kind == ScheduleKind.Custom;

    public string CronText => Schedule.Cron ?? Schedule.ExampleCron;

    public string CronDraft
    {
        get => CronText;
        set
        {
            var check = Schedule.Check(value, DateTimeOffset.Now, TimeZoneInfo.Local);
            if (check != CronCheck.Invalid)
            {
                Model.SetSchedule(Schedule.Custom(value.Trim()));
            }

            CronMessage = check switch
            {
                CronCheck.Invalid => Text.ScheduleCronInvalid,
                CronCheck.NeverRuns => Text.ScheduleCronNeverRuns,
                CronCheck.TooFrequent => Text.ScheduleCronTooFrequent,
                _ => string.Empty,
            };
            CronMessageBrush = StatusViewModel.TintBrush(check == CronCheck.Invalid ? StatusTint.Critical : StatusTint.Neutral);
        }
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasCronMessage))]
    public partial string CronMessage { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial Brush CronMessageBrush { get; private set; } = StatusViewModel.TintBrush(StatusTint.Neutral);

    public bool HasCronMessage => CronMessage.Length > 0;

    public string UpcomingRuns => Schedule.Kind == ScheduleKind.Manual || Model.Config.SchedulePaused
        ? string.Empty
        : string.Format(CultureInfo.CurrentCulture, Text.OverviewUpcomingRuns, Format.List(Schedule.UpcomingRuns(Model.Config.ScheduleReference, DateTimeOffset.Now, TimeZoneInfo.Local, 3).Select(run => Format.Relative(run, true)).ToList()));

    public bool HasUpcomingRuns => UpcomingRuns.Length > 0;

    public bool ShowsWeekday => Schedule.Kind == ScheduleKind.Weekly;

    public bool CanPauseSchedule => Schedule.Kind != ScheduleKind.Manual;

    public bool IsSchedulePaused => Model.Config.SchedulePaused;

    public string PauseLabel => IsSchedulePaused ? Text.OverviewResumeSchedule : Text.OverviewPauseSchedule;

    public string PauseGlyph => IsSchedulePaused ? Icons.Play : Icons.Pause;

    public IReadOnlyList<FolderItem> FolderPills => Model.Config.Folders.Take(PillLimit).Select(path => new FolderItem(path)).ToList();

    public string ExtraFolderText => $"+{Model.Config.Folders.Count - PillLimit}";

    public bool HasExtraFolders => Model.Config.Folders.Count > PillLimit;

    public bool HasFolders => Model.Config.Folders.Count > 0;

    public bool IsMissingRecoveryKey => Model.IsMissingRecoveryKey;

    public string ProtectedText => Model.ProtectedText;

    public string SnapshotCountText => Model.SnapshotsLoad == SnapshotsLoad.Loaded ? Model.Snapshots.Count.ToString("N0", CultureInfo.CurrentCulture) : Text.CommonUnknown;

    public string NextBackupTooltip => Model.NextRun is { } next ? Format.Absolute(next) : string.Empty;

    public BackupWarnings? Warnings => Model.Activity is null && Model.Config.LastRun is { Status: BackupStatus.Warn, Warnings: { Total: > 0 } warnings } ? warnings : null;

    public bool HasWarnings => Warnings is not null;

    public CloudOnlySkip? CloudOnly => Model.Activity is null && Model.Config.LastRun?.CloudOnlySkipped is { Count: > 0 } skip ? skip : null;

    public bool ShowsCloudOnlyNotice => CloudOnly is not null;

    public string CloudOnlyHeadline => CloudOnly?.Headline ?? string.Empty;

    public bool ShowsFailureNotificationHint => Model.Activity is null && Model.Config.ShowsFailureNotificationHint(Model.Config.SendsFailureNotifications);

    public bool IsMissingOnService => Model.MissingOnService;

    [RelayCommand]
    private void TogglePause() => Model.SetSchedulePaused(!IsSchedulePaused);

    [RelayCommand]
    private void TurnOnFailureNotifications() => Model.SetFailureNotifications(true);

    [RelayCommand]
    private void DismissFailureHint() => Model.UpdateConfig(config => config with { FailureNotificationHintDismissedAt = DateTimeOffset.Now });

    [RelayCommand]
    private void StartReplacement() => Model.StartReplacementBackup();

    [RelayCommand]
    private async Task ShowWarningsAsync()
    {
        if (Warnings is { } warnings)
        {
            await Platform.DialogHost.ShowAsync(new WarningsDialog(warnings));
        }
    }

    [RelayCommand]
    private async Task ShowCloudOnlyAsync()
    {
        if (CloudOnly is { } skip)
        {
            await Platform.DialogHost.ShowAsync(new CloudOnlyDialog(skip));
        }
    }
}
