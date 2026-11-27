using System.ComponentModel;
using System.Globalization;

using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.State;
using FutoBackups.Core.Strings;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Pages.Overview;

public sealed partial class CloudOnlyDialog : ContentDialog, INotifyPropertyChanged
{
    public CloudOnlyDialog(CloudOnlySkip skip)
    {
        Skip = skip;
        InitializeComponent();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public CloudOnlySkip Skip { get; }

    public string Intro => string.Format(CultureInfo.CurrentCulture, Text.OverviewCloudOnlyIntro, Skip.Headline);

    public string Paths => string.Join('\n', Skip.Sample);

    public string CopyLabel { get; private set; } = Text.OverviewCopyList;

    [RelayCommand]
    private void Copy()
    {
        Platform.FileExplorer.Copy(Paths);
        CopyLabel = Text.CommonCopied;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CopyLabel)));
    }
}
