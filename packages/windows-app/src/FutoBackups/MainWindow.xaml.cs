using FutoBackups.Core.Models;
using FutoBackups.Core.Status;
using FutoBackups.Core.Strings;
using FutoBackups.Pages;
using FutoBackups.Pages.Flow;
using FutoBackups.Pages.Settings;
using FutoBackups.ViewModels;

using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

using Windows.Graphics;

namespace FutoBackups;

public sealed partial class MainWindow : Window
{
    private static readonly Dictionary<string, Type> Pages = new()
    {
        ["overview"] = typeof(OverviewPage),
        ["folders"] = typeof(FoldersPage),
        ["history"] = typeof(HistoryPage),
        ["settings"] = typeof(SettingsPage),
    };

    private bool quitting;
    private ContentDialog? signInDialog;

    public MainWindow()
    {
        InitializeComponent();
        Title = Text.CommonAppName;
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Resize(new SizeInt32(1180, 820));
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 860;
            presenter.PreferredMinimumHeight = 600;
        }

        FlowFrame.Navigate(typeof(FlowPage));
        AppWindow.Closing += (_, args) =>
        {
            if (quitting) return;
            args.Cancel = true;
            AppWindow.Hide();
        };
        Shell.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(ShellViewModel.WaitingLogin))
            {
                ShowSignInWhenWaiting();
            }
            else if (args.PropertyName == nameof(ShellViewModel.IsInMain))
            {
                SelectFirstPageWhenShown();
            }
        };
        Platform.DialogHost.Closed += ShowSignInWhenWaiting;
        SelectFirstPageWhenShown();
        ShowSignInWhenWaiting();
    }

    public ShellViewModel Shell { get; } = new(App.Model);

    public StatusViewModel Status => App.Status;

    public SettingsViewModel Account { get; } = new(App.Model);

    private void ShowSignInWhenWaiting()
    {
        if (Shell.WaitingLogin is null)
        {
            signInDialog?.Hide();
            return;
        }

        if (signInDialog is null && !Platform.DialogHost.IsOpen)
        {
            _ = ShowSignInAsync(Shell.WaitingLogin);
        }
    }

    private async Task ShowSignInAsync(LoginState.Waiting login)
    {
        signInDialog = new SignInDialog(login);
        var result = await Platform.DialogHost.ShowAsync(signInDialog);
        signInDialog = null;
        if (result == ContentDialogResult.None)
        {
            Shell.CancelLoginCommand.Execute(null);
        }
    }

    private void SelectFirstPageWhenShown()
    {
        if (Shell.IsInMain && Navigation.SelectedItem is null)
        {
            Navigation.SelectedItem = Navigation.MenuItems[0];
        }
    }

    public void ShowFromTray()
    {
        AppWindow.Show();
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
        {
            presenter.Restore();
        }

        Activate();
    }

    public void Quit()
    {
        quitting = true;
        Close();
    }

    public void ShowPage(string tag)
    {
        Navigation.SelectedItem = Navigation.MenuItems.OfType<NavigationViewItem>().First(item => (string)item.Tag == tag);
    }

    private void Navigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.SelectedItem is NavigationViewItem { Tag: string tag })
        {
            ContentFrame.Navigate(Pages[tag]);
        }
    }
}
