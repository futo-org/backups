using System.Globalization;

using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Models;
using FutoBackups.Core.Strings;

namespace FutoBackups.ViewModels;

public sealed record ExclusionRow(string Pattern, string Label)
{
    public bool IsException => Pattern.StartsWith('!');

    public string Name => IsException ? $"{Label}, {Text.FoldersException}" : Label;
}

public sealed partial class ExclusionListViewModel(AppModel model) : ModelViewModel(model)
{
    private readonly HashSet<string> selected = [];

    public string Query
    {
        get;
        set
        {
            if (SetProperty(ref field, value))
            {
                NotifyChanges();
            }
        }
    } = string.Empty;

    public IReadOnlyList<ExclusionRow> Rows => Model.CustomExclusionsMatching(Query).Select(pattern => new ExclusionRow(pattern, Model.ExclusionLabel(pattern))).ToList();

    public string CountText => string.IsNullOrWhiteSpace(Query)
        ? string.Format(CultureInfo.CurrentCulture, Text.FoldersExclusionCount, Model.CustomExclusions.Count)
        : string.Format(CultureInfo.CurrentCulture, Text.FoldersExclusionsShown, Rows.Count, Model.CustomExclusions.Count);

    public string SelectionText => selected.Count == 0
        ? Text.FoldersSelectToRemove
        : string.Format(CultureInfo.CurrentCulture, Text.FoldersSelected, selected.Count);

    public bool HasSelection => selected.Count > 0;

    public bool IsSelected(ExclusionRow row) => selected.Contains(row.Pattern);

    public void Select(IEnumerable<ExclusionRow> rows)
    {
        selected.Clear();
        selected.UnionWith(rows.Select(row => row.Pattern));
        NotifyChanges();
    }

    [RelayCommand]
    private void RemoveSelected()
    {
        if (selected.Count == 0) return;
        var patterns = selected.ToList();
        selected.Clear();
        Model.RemoveExclusions(patterns);
    }
}
