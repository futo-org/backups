using System.ComponentModel;

using CommunityToolkit.Mvvm.Input;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Pages.Settings;

public sealed partial class UnlinkDialog : ContentDialog, INotifyPropertyChanged
{
    private bool confirmed;
    private bool unlinking;

    public UnlinkDialog()
    {
        InitializeComponent();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string? RevealedKey { get; private set; }

    public bool IsKeyRevealed => RevealedKey is not null;

    public bool IsKeyHidden => RevealedKey is null;

    public bool Confirmed
    {
        get => confirmed;
        set
        {
            confirmed = value;
            Changed(nameof(Confirmed), nameof(CanUnlink));
        }
    }

    public bool IsUnlinking => unlinking;

    public bool IsAsking => !unlinking;

    public bool CanUnlink => confirmed && !unlinking;

    [RelayCommand]
    private async Task RevealKeyAsync()
    {
        RevealedKey = await App.Model.RevealRecoveryKeyAsync();
        Changed(nameof(RevealedKey), nameof(IsKeyRevealed), nameof(IsKeyHidden));
    }

    private async void Unlink_Click(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        unlinking = true;
        Changed(nameof(IsUnlinking), nameof(IsAsking), nameof(CanUnlink));
        await App.Model.ResetThisPcAsync();
        deferral.Complete();
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }
    }
}
