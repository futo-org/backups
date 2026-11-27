using FutoBackups.Core.Models;
using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace FutoBackups.Pages;

public sealed partial class ExclusionListDialog : ContentDialog
{
    private bool restoring;

    public ExclusionListDialog(AppModel model)
    {
        ViewModel = new ExclusionListViewModel(model);
        InitializeComponent();
        ViewModel.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ExclusionListViewModel.Rows))
            {
                restoring = true;
                DispatcherQueue.TryEnqueue(RestoreSelection);
            }
        };
        Closed += (_, _) => ViewModel.Dispose();
    }

    public ExclusionListViewModel ViewModel { get; }

    private void RestoreSelection()
    {
        foreach (var row in ViewModel.Rows.Where(ViewModel.IsSelected))
        {
            List.SelectedItems.Add(row);
        }

        restoring = false;
        ViewModel.Select(List.SelectedItems.OfType<ExclusionRow>());
    }

    private void List_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!restoring)
        {
            ViewModel.Select(List.SelectedItems.OfType<ExclusionRow>());
        }
    }

    private void Delete_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        ViewModel.RemoveSelectedCommand.Execute(null);
    }
}
