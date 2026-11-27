using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Pages.Settings;

public sealed partial class ChangeRecoveryKeyDialog : ContentDialog
{
    public ChangeRecoveryKeyDialog()
    {
        ViewModel = new ChangeRecoveryKeyViewModel(App.Model);
        InitializeComponent();
    }

    public ChangeRecoveryKeyViewModel ViewModel { get; }

    private void Primary_Click(ContentDialog sender, ContentDialogButtonClickEventArgs args) => args.Cancel = !ViewModel.IsFinished;

    private void KeepOpen(ContentDialog sender, ContentDialogButtonClickEventArgs args) => args.Cancel = true;
}
