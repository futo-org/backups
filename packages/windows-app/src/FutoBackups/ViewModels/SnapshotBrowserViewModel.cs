using System.Globalization;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Models;
using FutoBackups.Core.Restic;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;
using FutoBackups.ResticWrapper;

namespace FutoBackups.ViewModels;

public sealed partial class Crumb(string title, int depth, Action<int> open)
{
    public string Title => title;

    public bool ShowsSeparator => depth > 0;

    [RelayCommand]
    private void Open() => open(depth);
}

public sealed partial class EntryRow(SnapshotEntry entry, bool showsPath, SnapshotBrowserViewModel browser) : ObservableObject
{
    public SnapshotEntry Entry => entry;

    public bool ShowsPath => showsPath;

    public string DisplayPath => ResticTreePath.ToLocal(entry.Path);

    public string Glyph => entry.IsDirectory ? Icons.Folder : Icons.Document;

    public string ModifiedText => entry.Modified is { } modified ? Format.Absolute(modified) : Text.RestoreNoValue;

    public string SizeText => entry.IsDirectory || entry.Size is null ? Text.RestoreNoValue : Format.Bytes(entry.Size);

    public string OpenLabel => string.Format(CultureInfo.CurrentCulture, Text.RestoreOpen, entry.Name);

    public bool IsCovered => browser.IsCoveredByFolder(entry.Path);

    public bool IsSelectable => !IsCovered;

    public string? CoveredHelp => IsCovered ? Text.RestoreIncludedWithFolder : null;

    public bool IsIncluded
    {
        get => IsCovered || browser.IsSelected(entry.Path);
        set
        {
            if (IsCovered || value == IsIncluded) return;
            browser.SetIncluded(entry, value);
        }
    }

    public override string ToString() => entry.Name;

    public void SelectionChanged()
    {
        OnPropertyChanged(nameof(IsCovered));
        OnPropertyChanged(nameof(IsSelectable));
        OnPropertyChanged(nameof(CoveredHelp));
        OnPropertyChanged(nameof(IsIncluded));
    }

    [RelayCommand]
    private void Open() => browser.Open(entry);

    [RelayCommand]
    private void Toggle()
    {
        if (!entry.IsDirectory)
        {
            IsIncluded = !IsIncluded;
        }
    }
}

public sealed partial class SnapshotBrowserViewModel : ObservableObject, IDisposable
{
    private readonly List<SnapshotEntry> trail = [];
    private readonly Dictionary<string, SnapshotEntry> selected = [];
    private readonly AppModel model;
    private readonly CancellationTokenSource closing = new();
    private CancellationTokenSource? listing;

    public SnapshotBrowserViewModel(Snapshot snapshot, AppModel model)
    {
        this.model = model;
        Snapshot = snapshot;
        _ = ShowAsync();
    }

    public Snapshot Snapshot { get; }

    public string Subtitle => string.Format(CultureInfo.CurrentCulture, Text.RestorePickFiles, Format.Relative(Snapshot.Time, true));

    public IReadOnlyList<SnapshotEntry> SelectedEntries => selected.Values.ToList();

    [ObservableProperty]
    public partial IReadOnlyList<Crumb> Crumbs { get; private set; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowsEmpty))]
    public partial IReadOnlyList<EntryRow> Rows { get; private set; } = [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowsEmpty))]
    public partial bool IsLoading { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(ShowsEmpty))]
    public partial string? Failure { get; private set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(BackCommand))]
    public partial bool CanGoBack { get; private set; }

    public bool ShowsEmpty => !IsLoading && (Failure is not null || Rows.Count == 0);

    public string EmptyText => Failure ?? Text.RestoreFolderEmpty;

    public bool ShowsRetry => Failure is not null;

    public bool HasSelection => selected.Count > 0;

    public bool CanRestore => HasSelection && model.CanRestore;

    public string SelectionText => selected.Count switch
    {
        0 => Text.RestoreSelectFiles,
        1 => Text.RestoreOneItemSelected,
        _ => string.Format(CultureInfo.CurrentCulture, Text.RestoreItemsSelected, selected.Count),
    };

    public string RestoreTitle => selected.Count switch
    {
        0 => Text.RestoreRestore,
        1 => Text.RestoreRestoreOneItem,
        _ => string.Format(CultureInfo.CurrentCulture, Text.RestoreRestoreItems, selected.Count),
    };

    public void Dispose()
    {
        closing.Cancel();
        closing.Dispose();
        listing?.Dispose();
    }

    public bool IsSelected(string path) => selected.ContainsKey(path);

    public bool IsCoveredByFolder(string path) =>
        selected.Values.Any(entry => entry.IsDirectory && path.StartsWith(entry.Path.TrimEnd('/') + "/", StringComparison.Ordinal));

    public void SetIncluded(SnapshotEntry entry, bool included)
    {
        if (included)
        {
            foreach (var inside in selected.Keys.Where(path => entry.IsDirectory && path.StartsWith(entry.Path.TrimEnd('/') + "/", StringComparison.Ordinal)).ToList())
            {
                selected.Remove(inside);
            }

            selected[entry.Path] = entry;
        }
        else
        {
            selected.Remove(entry.Path);
        }

        SelectionChanged();
    }

    public void Open(SnapshotEntry entry)
    {
        if (!entry.IsDirectory) return;
        trail.Add(entry);
        _ = ShowAsync();
    }

    [RelayCommand(CanExecute = nameof(CanGoBack))]
    private void Back()
    {
        trail.RemoveAt(trail.Count - 1);
        _ = ShowAsync();
    }

    [RelayCommand]
    private Task RetryAsync() => ShowAsync();

    [RelayCommand]
    private void Clear()
    {
        selected.Clear();
        SelectionChanged();
    }

    private void OpenDepth(int depth)
    {
        trail.RemoveRange(depth, trail.Count - depth);
        _ = ShowAsync();
    }

    private void SelectionChanged()
    {
        foreach (var row in Rows)
        {
            row.SelectionChanged();
        }

        OnPropertyChanged(nameof(HasSelection));
        OnPropertyChanged(nameof(CanRestore));
        OnPropertyChanged(nameof(SelectionText));
        OnPropertyChanged(nameof(RestoreTitle));
    }

    private async Task ShowAsync()
    {
        listing?.Cancel();
        listing?.Dispose();
        var cancellation = listing = CancellationTokenSource.CreateLinkedTokenSource(closing.Token);
        var atRoot = trail.Count == 0;
        CanGoBack = !atRoot;
        Crumbs = trail.Select((entry, index) => new Crumb(entry.Name, index + 1, OpenDepth)).Prepend(new Crumb(Text.RestoreBackedUpFolders, 0, OpenDepth)).ToList();
        Rows = [];
        Failure = null;
        IsLoading = !atRoot;
        OnPropertyChanged(nameof(EmptyText));
        OnPropertyChanged(nameof(ShowsRetry));
        IReadOnlyList<SnapshotEntry> entries;
        try
        {
            entries = atRoot ? SnapshotListing.Roots(Snapshot.Paths) : await model.ListDirectoryAsync(Snapshot, trail[^1].Path, cancellation.Token);
        }
        catch (Exception error) when (!cancellation.IsCancellationRequested)
        {
            IsLoading = false;
            Failure = model.Describe(error);
            OnPropertyChanged(nameof(EmptyText));
            OnPropertyChanged(nameof(ShowsRetry));
            return;
        }
        catch (Exception)
        {
            return;
        }

        if (cancellation.IsCancellationRequested) return;
        IsLoading = false;
        Rows = entries.Select(entry => new EntryRow(entry, atRoot, this)).ToList();
    }
}
