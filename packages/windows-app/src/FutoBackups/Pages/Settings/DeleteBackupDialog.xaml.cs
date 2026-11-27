using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Pages.Settings;

public sealed partial class DeleteBackupDialog : ContentDialog
{
    public DeleteBackupDialog()
    {
        ViewModel = new DeleteBackupViewModel(App.Model);
        InitializeComponent();
        ViewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(DeleteBackupViewModel.IsFinished) && ViewModel.IsFinished)
            {
                Hide();
            }
        };
        Closed += (_, _) =>
        {
            App.Model.DismissBackupDeletion();
            ViewModel.Dispose();
        };
    }

    public DeleteBackupViewModel ViewModel { get; }

    private void KeepOpen(ContentDialog sender, ContentDialogButtonClickEventArgs args) => args.Cancel = true;

    private void Dialog_CloseButtonClick(ContentDialog sender, ContentDialogButtonClickEventArgs args) => ViewModel.Close();
}
