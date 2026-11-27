using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Controls;

public sealed partial class ServerEditor : UserControl
{
    public ServerEditor()
    {
        InitializeComponent();
    }

    public ServerEditorViewModel ViewModel { get; } = new(App.Model);
}
