using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Controls;

public sealed partial class StartupFailureBar : UserControl
{
    public StartupFailureBar()
    {
        InitializeComponent();
    }

    public StartupFailureViewModel ViewModel { get; } = new(App.Model);
}
