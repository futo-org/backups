using FutoBackups.Core.Strings;
using FutoBackups.ViewModels;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace FutoBackups.Pages;

public sealed partial class FoldersPage : Page
{
    public FoldersPage()
    {
        InitializeComponent();
        ViewModel.PatternAdded += PatternFlyout.Hide;
    }

    public FoldersViewModel ViewModel { get; } = new(App.Model);

    private void Folders_DragOver(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        e.AcceptedOperation = DataPackageOperation.Link;
        e.DragUIOverride.Caption = Text.FoldersBackUp;
    }

    private async void Folders_Drop(object sender, DragEventArgs e)
    {
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
        var items = await e.DataView.GetStorageItemsAsync();
        ViewModel.AddFolders(items.OfType<StorageFolder>().Select(folder => folder.Path));
    }

    private void CancelPattern_Click(object sender, RoutedEventArgs e) => PatternFlyout.Hide();
}
