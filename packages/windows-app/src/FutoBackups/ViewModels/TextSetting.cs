using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace FutoBackups.ViewModels;

public sealed partial class TextSetting : ObservableObject
{
    private readonly Func<string> read;
    private readonly Func<string, Task<string?>> write;
    private string committed;
    private string draft;

    public TextSetting(Func<string> read, Func<string, Task<string?>> write)
    {
        this.read = read;
        this.write = write;
        committed = read();
        draft = committed;
    }

    public string Draft
    {
        get => draft;
        set
        {
            if (!SetProperty(ref draft, value)) return;
            Error = null;
            IsSaved = false;
        }
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasError))]
    public partial string? Error { get; private set; }

    public bool HasError => Error is not null;

    [ObservableProperty]
    public partial bool IsSaved { get; private set; }

    public void Refresh()
    {
        var current = read();
        if (draft == committed && Error is null)
        {
            SetProperty(ref draft, current, nameof(Draft));
        }

        committed = current;
    }

    [RelayCommand]
    private async Task ApplyAsync()
    {
        if (draft == committed) return;
        var error = await write(draft);
        Error = error;
        if (error is not null) return;
        committed = read();
        SetProperty(ref draft, committed, nameof(Draft));
        IsSaved = true;
    }
}
