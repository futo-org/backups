using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace FutoBackups.Pages.Flow;

public sealed partial class FlowPage : Page
{
    public FlowPage()
    {
        InitializeComponent();
    }

    public FlowViewModel Flow { get; } = new(App.Model);

    private void Escape_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args) => args.Handled = Flow.GoBack();
}
