using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.State;

namespace FutoBackups.ViewModels;

public sealed partial class RetentionFieldItem(RetentionField retentionField, Action edited) : ObservableObject
{
    private string draft = string.Empty;

    public RetentionField Field => retentionField;

    public string Title => retentionField.Title();

    public string Detail => retentionField.Detail();

    public string Placeholder => retentionField.Placeholder();

    public string Draft
    {
        get => draft;
        set
        {
            if (!SetProperty(ref draft, value)) return;
            Error = null;
            edited();
        }
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    public partial string? Error { get; set; }

    public bool HasError => Error is not null;

    public void Load(string value)
    {
        SetProperty(ref draft, value, nameof(Draft));
        Error = null;
    }
}

public sealed partial class RetentionEditor : ObservableObject
{
    private readonly Func<SnapshotRetention, Task> request;
    private readonly Func<SnapshotRetention> current;

    public RetentionEditor(Func<SnapshotRetention> current, Func<SnapshotRetention, Task> request)
    {
        this.current = current;
        this.request = request;
        Fields = RetentionFields.All.Select(field => new RetentionFieldItem(field, Edited)).ToList();
        Load();
    }

    public IReadOnlyList<RetentionFieldItem> Fields { get; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    public partial string? Error { get; private set; }

    public bool HasError => Error is not null;

    [ObservableProperty]
    public partial bool IsSaved { get; private set; }

    public void Load()
    {
        var draft = new RetentionDraft(current().Policy);
        foreach (var item in Fields)
        {
            item.Load(draft[item.Field]);
        }

        Error = null;
    }

    [RelayCommand]
    private async Task ApplyAsync()
    {
        var draft = new RetentionDraft();
        foreach (var item in Fields)
        {
            draft[item.Field] = item.Draft;
        }

        RetentionPolicy policy;
        try
        {
            policy = draft.Policy();
        }
        catch (RetentionInputException error)
        {
            var errors = draft.Errors;
            foreach (var item in Fields)
            {
                item.Error = errors.TryGetValue(item.Field, out var fieldError) ? Retention.Message(fieldError) : null;
            }

            Error = errors.Count == 0 ? error.Message : null;
            return;
        }

        var retention = new SnapshotRetention(policy);
        await request(retention);
        IsSaved = current() == retention;
    }

    private void Edited()
    {
        Error = null;
        IsSaved = false;
    }
}
