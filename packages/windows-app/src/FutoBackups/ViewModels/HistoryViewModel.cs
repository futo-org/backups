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
using FutoBackups.Pages.History;
using FutoBackups.Pages.Overview;
using FutoBackups.Platform;
using FutoBackups.ResticWrapper;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.ViewModels;

public sealed record SnapshotItem(Snapshot Snapshot, bool IsLatest, bool IsFirstInDay, BackupWarnings? Warnings, bool CanRestore)
{
    public string TimeText => Format.Time(Snapshot.Time);

    public string TimeTooltip => Format.Absolute(Snapshot.Time);

    public string Summary => string.Join(" · ", new[]
    {
        Snapshot.TotalFilesProcessed is { } files ? Format.Count(files, Text.CommonOneFile, Text.HistoryFiles) : null,
        Snapshot.TotalBytesProcessed is { } bytes ? Format.Bytes(bytes) : null,
    }.OfType<string>());

    public string AddedText => Snapshot.DataAdded is { } added ? $"+{Format.Bytes(added)}" : string.Empty;

    public bool HasAdded => Snapshot.DataAdded is not null;

    public bool IsOlder => !IsLatest;

    public bool HasWarnings => Warnings is { Total: > 0 };

    public string WarningsText => Warnings?.Total == 1 ? Text.HistoryOneWarning : string.Format(CultureInfo.CurrentCulture, Text.HistoryWarnings, Warnings?.Total);

    public string ShortId => Snapshot.ShortId;

    public Thickness Divider => IsFirstInDay ? new Thickness(0) : new Thickness(0, 1, 0, 0);
}

public sealed record SnapshotDay(string Title, IReadOnlyList<SnapshotItem> Snapshots)
{
    public bool Equals(SnapshotDay? other) => other is not null && Title == other.Title && Snapshots.SequenceEqual(other.Snapshots);

    public override int GetHashCode() => HashCode.Combine(Title, Snapshots.Count);
}

public sealed record RunItem(string Title, string Detail, string Glyph, bool IsRunning, string? SupportLog = null, string? SupportCode = null)
{
    public bool HasSupportLog => SupportLog is not null && File.Exists(SupportLog);

    public bool HasSupportCode => SupportCode is not null;

    public string SupportCodeText => SupportCode is { } code ? string.Format(CultureInfo.CurrentCulture, Text.HistorySupportCode, code) : string.Empty;

    public static RunItem From(RunEntry run) => new(
        run.Title,
        string.Join(" · ", new[] { Format.Absolute(run.StartedAt), RunHistory.DurationText(run.Duration), run.Message }.OfType<string>()),
        run.Kind == RunKind.Restore ? Icons.Download : run.Status switch
        {
            BackupStatus.Complete => Icons.CheckMark,
            BackupStatus.Warn => Icons.Warning,
            BackupStatus.Failed => Icons.Cancel,
            _ => Icons.Pause,
        },
        false,
        run.SupportLog,
        run.SupportCode);
}

public sealed partial class HistoryViewModel(AppModel model) : ModelViewModel(model)
{
    private bool awaitingRestore;

    [ObservableProperty]
    public partial string RestoreResultTitle { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string RestoreResultMessage { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial InfoBarSeverity RestoreResultSeverity { get; private set; }

    [ObservableProperty]
    public partial bool CanRevealRestored { get; private set; }

    [ObservableProperty]
    public partial bool IsRestoreResultOpen { get; set; }

    protected override void OnModelChanged()
    {
        if (!awaitingRestore || Model.Activity is not null) return;
        awaitingRestore = false;
        if (Model.Config.Runs is not [{ Kind: RunKind.Restore } run, ..]) return;
        CanRevealRestored = Model.RestoredFolders.Count > 0;
        RestoreResultSeverity = run.Status switch
        {
            BackupStatus.Complete => InfoBarSeverity.Success,
            BackupStatus.Cancelled => InfoBarSeverity.Informational,
            BackupStatus.Failed => InfoBarSeverity.Error,
            _ => InfoBarSeverity.Warning,
        };
        RestoreResultTitle = run.Title;
        RestoreResultMessage = CanRevealRestored ? string.Join(", ", Model.RestoredFolders) : run.Message ?? string.Empty;
        IsRestoreResultOpen = true;
    }

    [RelayCommand]
    private Task RefreshAsync() => Model.RefreshSnapshotsAsync();

    [RelayCommand]
    private void RevealRestored()
    {
        if (Model.RestoredFolders is [{ } folder, ..])
        {
            FileExplorer.Reveal(folder);
        }
    }

    [RelayCommand]
    private async Task SaveSupportLogAsync(string source)
    {
        var target = await Pickers.PickSaveFileAsync(App.Window!, Path.GetFileName(source), Text.HistorySupportLogFileType, ".ndjson");
        if (target is null) return;
        try
        {
            File.Copy(source, target, true);
        }
        catch (Exception error)
        {
            Model.LastError = ErrorMessage.Text(error, Model.Config.ServerDisplayName);
        }
    }

    [RelayCommand]
    private static async Task ShowWarningsAsync(SnapshotItem item)
    {
        if (item.Warnings is { } warnings)
        {
            await DialogHost.ShowAsync(new WarningsDialog(warnings));
        }
    }

    [RelayCommand]
    private async Task BrowseAsync(SnapshotItem item)
    {
        var browser = new SnapshotBrowser(item.Snapshot, Model);
        var result = await DialogHost.ShowAsync(browser);
        if (result != ContentDialogResult.Primary) return;
        var target = await PickTargetAsync();
        if (target is null) return;
        Model.RestoreSelection(item.Snapshot, browser.ViewModel.SelectedEntries, target);
    }

    [RelayCommand]
    private async Task RestoreAsync(SnapshotItem item)
    {
        var target = await PickTargetAsync();
        if (target is null) return;
        Model.RestoreSnapshot(item.Snapshot, target);
    }

    private async Task<string?> PickTargetAsync()
    {
        var path = await Pickers.PickFolderAsync(App.Window!, Text.HistoryRestoreHere, Pickers.DownloadsFolder);
        if (path is null) return null;
        IsRestoreResultOpen = false;
        awaitingRestore = true;
        return path;
    }

    private static readonly BackupStatus?[] RunFilters = [null, BackupStatus.Complete, BackupStatus.Warn, BackupStatus.Failed, BackupStatus.Cancelled, BackupStatus.Incomplete];

    public static IReadOnlyList<string> RunFilterLabels => [Text.HistoryFilterAll, Text.HistoryFilterComplete, Text.HistoryFilterWarnings, Text.HistoryFilterFailed, Text.StatusCancelled, Text.HistoryFilterInterrupted];

    private int runFilterIndex;
    private string runQuery = string.Empty;

    public int RunFilterIndex
    {
        get => runFilterIndex;
        set
        {
            if (value < 0 || !SetProperty(ref runFilterIndex, value)) return;
            OnPropertyChanged(nameof(Runs));
            OnPropertyChanged(nameof(HasRuns));
            OnPropertyChanged(nameof(HasNoRuns));
        }
    }

    public string RunQuery
    {
        get => runQuery;
        set
        {
            if (!SetProperty(ref runQuery, value)) return;
            OnPropertyChanged(nameof(Runs));
            OnPropertyChanged(nameof(HasRuns));
            OnPropertyChanged(nameof(HasNoRuns));
        }
    }

    public IReadOnlyList<RunItem> Runs
    {
        get
        {
            var finished = RunHistory.Filtered(Model.Config.Runs, RunFilters[runFilterIndex], runQuery).Select(RunItem.From);
            var running = Model.Activity is { } activity && runFilterIndex == 0
                ? [new RunItem(App.Status.StatusTitle, string.Format(CultureInfo.CurrentCulture, Text.HistoryStarted, Format.Relative(DateTimeOffset.Now)), activity == ActivityPhase.Restoring ? Icons.Download : Icons.Upload, true)]
                : Array.Empty<RunItem>();
            return running.Concat(finished).ToList();
        }
    }

    public bool HasNoRuns => Runs.Count == 0;

    public bool HasRuns => !HasNoRuns;

    public string RetentionLine => string.Format(CultureInfo.CurrentCulture, Text.HistoryRetentionLine, Model.Config.SnapshotRetention.Summary);

    public IReadOnlyList<SnapshotDay> SnapshotDays
    {
        get
        {
            var snapshots = Model.Snapshots;
            var latest = snapshots.Count > 0 ? snapshots[0] : null;
            return snapshots
                .GroupBy(snapshot => snapshot.Time.ToLocalTime().Date)
                .Select(day => new SnapshotDay(Format.Day(day.Key), day.Select((snapshot, index) =>
                    new SnapshotItem(snapshot, snapshot == latest, index == 0, Model.Config.LastRun?.WarningsForSnapshot(snapshot.Id), Model.CanRestore)).ToList()))
                .ToList();
        }
    }

    public bool HasSnapshots => Model.Snapshots.Count > 0;

    public bool ShowsSnapshotsLoading => !HasSnapshots && Model.SnapshotsLoad is SnapshotsLoad.Loading or SnapshotsLoad.NotLoaded;

    public bool ShowsSnapshotsEmpty => !HasSnapshots && Model.SnapshotsLoad == SnapshotsLoad.Loaded;

    public bool ShowsSnapshotsFailed => !HasSnapshots && Model.SnapshotsLoad == SnapshotsLoad.Failed;

    public string SnapshotsError => Model.SnapshotsError ?? string.Empty;

    public bool CanRefreshSnapshots => Model.SnapshotsLoad != SnapshotsLoad.Loading;

    public bool IsRestoring => Model.Activity == ActivityPhase.Restoring;

    public bool CanRestore => Model.CanRestore;

    public bool RestoreStoppedEarly => Model.RestoreStoppedEarly;
}
