using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Pages;

public sealed partial class HistoryPage : Page
{
    public HistoryPage()
    {
        InitializeComponent();
        ViewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(HistoryViewModel.IsRestoreResultOpen) && ViewModel.IsRestoreResultOpen)
            {
                RestoreInfo.StartBringIntoView();
            }
        };
    }

    public HistoryViewModel ViewModel { get; } = new(App.Model);

    public StatusViewModel Status => App.Status;
}
