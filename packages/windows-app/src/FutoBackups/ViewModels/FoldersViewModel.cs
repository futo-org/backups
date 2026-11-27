using System.Globalization;
using System.Windows.Input;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core;
using FutoBackups.Core.Models;
using FutoBackups.Core.Onboarding;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;
using FutoBackups.Pages;
using FutoBackups.Platform;

namespace FutoBackups.ViewModels;

public sealed record ExclusionItem(string Pattern, ICommand Remove)
{
    public string RemoveLabel => string.Format(CultureInfo.CurrentCulture, Text.FoldersStopExcludingName, Pattern);
}

public sealed record BundleItem(FolderBundle Bundle, IReadOnlyList<string> Paths)
{
    public string Title => Bundle.Title();

    public string Detail => Bundle.Detail();

    public string Glyph => Icons.For(Bundle);
}

public sealed partial class FoldersViewModel(AppModel model) : ModelViewModel(model)
{
    private static readonly WindowsKnownFolders Known = new();

    public event Action? PatternAdded;

    public IReadOnlyList<FolderItem> Folders => Model.Config.Folders.Select(path => new FolderItem(path)).ToList();

    public IReadOnlyList<ExclusionItem> BuiltInExclusions => Model.Config.Excludes.Where(Model.IsDefaultExclusion).Select(pattern => new ExclusionItem(pattern, RemoveExclusionCommand)).ToList();

    public IReadOnlyList<BundleItem> FolderBundles { get; } = Core.Onboarding.FolderBundles.All
        .Select(bundle => new BundleItem(bundle, new FolderSelection(Known, bundle).Paths))
        .ToList();

    public bool HasNoFolders => Model.Config.Folders.Count == 0;

    public bool HasNoExclusions => Model.CustomExclusions.Count == 0;

    public bool HasExclusions => !HasNoExclusions;

    public string ExclusionSummary => Format.Count(Model.CustomExclusions.Count, Text.FoldersOneExcludedItem, Text.FoldersExcludedItems);

    public string BuiltInHeader => string.Format(CultureInfo.CurrentCulture, Text.FoldersBuiltInHeader, BuiltInExclusions.Count);

    public bool IsMissingBuiltIns => !Model.HasAllDefaultExclusions;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(BuiltInChevron))]
    public partial bool IsBuiltInExpanded { get; private set; }

    public string BuiltInChevron => IsBuiltInExpanded ? Icons.ChevronDown : Icons.ChevronRight;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasPatternError), nameof(ShowsPatternHint))]
    public partial string? PatternError { get; private set; }

    public bool HasPatternError => PatternError is not null;

    public bool ShowsPatternHint => PatternError is null;

    public string PatternDraft
    {
        get;
        set
        {
            if (SetProperty(ref field, value))
            {
                PatternError = null;
            }
        }
    } = string.Empty;

    public void AddFolders(IEnumerable<string> paths) => Model.AddFolders(paths);

    public void ResetPattern()
    {
        PatternDraft = string.Empty;
        PatternError = null;
    }

    [RelayCommand]
    private void AddPattern()
    {
        PatternError = Model.AddExclusionPattern(PatternDraft);
        if (PatternError is null)
        {
            PatternAdded?.Invoke();
        }
    }

    [RelayCommand]
    private async Task AddFolderAsync()
    {
        var path = await Pickers.PickFolderAsync(App.Window!);
        if (path is not null)
        {
            Model.AddFolders([path]);
        }
    }

    [RelayCommand]
    private void AddPreset(BundleItem bundle) => Model.AddFolders(bundle.Paths);

    [RelayCommand]
    private void RemoveFolder(FolderItem folder) => Model.RemoveFolder(folder.Path);

    [RelayCommand]
    private static void ShowInExplorer(FolderItem folder) => FileExplorer.Open(folder.Path);

    [RelayCommand]
    private async Task ExcludeFolderAsync()
    {
        var path = await Pickers.PickFolderAsync(App.Window!);
        if (path is not null)
        {
            Model.AddExcludedPaths([path]);
        }
    }

    [RelayCommand]
    private async Task ExcludeFileAsync()
    {
        var path = await Pickers.PickFileAsync(App.Window!);
        if (path is not null)
        {
            Model.AddExcludedPaths([path]);
        }
    }

    [RelayCommand]
    private Task ShowExclusionsAsync() => DialogHost.ShowAsync(new ExclusionListDialog(Model));

    [RelayCommand]
    private void RemoveExclusion(string pattern) => Model.RemoveExclusion(pattern);

    [RelayCommand]
    private void RestoreBuiltInExclusions() => Model.RestoreDefaultExclusions();

    [RelayCommand]
    private void ToggleBuiltIns() => IsBuiltInExpanded = !IsBuiltInExpanded;
}
