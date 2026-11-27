using FutoBackups.Core.Restic;
using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Pages.Overview;

public sealed partial class WarningsDialog : ContentDialog
{
    public WarningsDialog(BackupWarnings warnings)
    {
        ViewModel = new WarningsViewModel(App.Model, warnings);
        InitializeComponent();
        Closed += (_, _) => ViewModel.Dispose();
    }

    public WarningsViewModel ViewModel { get; }
}
