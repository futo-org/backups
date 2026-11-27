using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

using Windows.System;

namespace FutoBackups.Pages;

public sealed partial class OverviewPage : Page
{
    public OverviewPage()
    {
        InitializeComponent();
    }

    public StatusViewModel Status => App.Status;

    public OverviewViewModel ViewModel { get; } = new(App.Model);

    private void CronBox_KeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            ViewModel.CronDraft = CronBox.Text;
        }
    }
}
