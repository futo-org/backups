using System.Globalization;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Models;
using FutoBackups.Core.Restic;
using FutoBackups.Core.Strings;

namespace FutoBackups.ViewModels;

public sealed partial class WarningRow(BackupWarning warning, Action<string> exclude) : ObservableObject
{
    public string Path => warning.Path;

    public string Reason => warning.Reason;

    public string ExcludeName => string.Format(CultureInfo.CurrentCulture, Text.OverviewExcludeName, warning.Path);

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanExclude))]
    public partial bool IsExcluded { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanExclude))]
    public partial bool IsInFolders { get; set; }

    public bool CanExclude => !IsExcluded && !IsInFolders;

    [RelayCommand]
    private void Exclude() => exclude(Path);
}

public sealed partial class WarningsViewModel : ModelViewModel
{
    private readonly BackupWarnings warnings;

    public WarningsViewModel(AppModel model, BackupWarnings warnings)
        : base(model)
    {
        this.warnings = warnings;
        Rows = warnings.Items.Select(warning => new WarningRow(warning, path => model.AddExcludedPaths([path]))).ToList();
        OnModelChanged();
    }

    public string Headline => warnings.Headline;

    public string ListTitle => warnings.ListTitle;

    public IReadOnlyList<WarningRow> Rows { get; }

    public bool CanExcludeAll => Rows.Any(row => row.CanExclude);

    [ObservableProperty]
    public partial string CopyLabel { get; private set; } = Text.OverviewCopyList;

    protected override void OnModelChanged()
    {
        foreach (var row in Rows)
        {
            row.IsExcluded = Model.IsExcludedPath(row.Path);
            row.IsInFolders = !row.IsExcluded && !Model.CanExcludePath(row.Path);
        }
    }

    [RelayCommand]
    private void ExcludeAll() => Model.AddExcludedPaths(Rows.Where(row => row.CanExclude).Select(row => row.Path).ToList());

    [RelayCommand]
    private void Copy()
    {
        Platform.FileExplorer.Copy(warnings.ListText());
        CopyLabel = Text.CommonCopied;
    }
}
