using FutoBackups.Core.Models;
using FutoBackups.ResticWrapper;
using FutoBackups.ViewModels;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;

namespace FutoBackups.Pages.History;

public sealed partial class SnapshotBrowser : ContentDialog
{
    public SnapshotBrowser(Snapshot snapshot, AppModel model)
    {
        ViewModel = new SnapshotBrowserViewModel(snapshot, model);
        InitializeComponent();
        Closed += (_, _) => ViewModel.Dispose();
    }

    public SnapshotBrowserViewModel ViewModel { get; }

    private static bool StartsOnControl(object source, object row)
    {
        for (var current = source as DependencyObject; current is not null && !ReferenceEquals(current, row); current = VisualTreeHelper.GetParent(current))
        {
            if (current is CheckBox or Button) return true;
        }

        return false;
    }

    private void Row_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        if (!StartsOnControl(e.OriginalSource, sender) && sender is FrameworkElement { DataContext: EntryRow row })
        {
            row.OpenCommand.Execute(null);
        }
    }

    private void Row_Tapped(object sender, TappedRoutedEventArgs e)
    {
        if (!StartsOnControl(e.OriginalSource, sender) && sender is FrameworkElement { DataContext: EntryRow row })
        {
            row.ToggleCommand.Execute(null);
        }
    }
}
