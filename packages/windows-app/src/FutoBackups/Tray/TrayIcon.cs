using System.Globalization;

using FutoBackups.Core.Strings;
using FutoBackups.ViewModels;

using H.NotifyIcon;
using H.NotifyIcon.Core;

using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;

namespace FutoBackups.Tray;

public sealed class TrayIcon : IDisposable
{
    private readonly TaskbarIcon icon;
    private readonly TrayFlyout flyout;
    private readonly MenuFlyoutItem title = new() { IsEnabled = false };
    private readonly MenuFlyoutItem lastBackup = new() { IsEnabled = false };
    private readonly MenuFlyoutItem nextBackup = new() { IsEnabled = false };
    private readonly MenuFlyoutItem backUpOrCancel = new();

    public TrayIcon(Action open, Action quit)
    {
        var openItem = new MenuFlyoutItem { Text = Text.TrayOpen };
        var quitItem = new MenuFlyoutItem { Text = Text.TrayQuit };
        var helpItem = new MenuFlyoutItem { Text = Text.CommonAppHelp };
        helpItem.Click += (_, _) => Platform.FileExplorer.OpenUrl(Platform.FileExplorer.HelpUrl);
        openItem.Click += (_, _) => open();
        quitItem.Click += (_, _) => quit();
        backUpOrCancel.Click += (_, _) =>
        {
            if (!State.ShowsCancelAction)
            {
                App.Status.BackUpNowCommand.Execute(null);
                return;
            }

            open();
            App.Status.CancelCommand.Execute(null);
        };
        var menu = new MenuFlyout();
        foreach (var item in new MenuFlyoutItemBase[] { title, lastBackup, nextBackup, new MenuFlyoutSeparator(), backUpOrCancel, openItem, helpItem, new MenuFlyoutSeparator(), quitItem })
        {
            menu.Items.Add(item);
        }

        flyout = new TrayFlyout(open, quit);
        var toggleCommand = new XamlUICommand();
        toggleCommand.ExecuteRequested += (_, _) => flyout.Toggle();
        icon = new TaskbarIcon
        {
            ContextMenuMode = ContextMenuMode.PopupMenu,
            ContextFlyout = menu,
            LeftClickCommand = toggleCommand,
            NoLeftClickDelay = true,
            IconSource = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"))),
        };
        State.PropertyChanged += (_, _) => Update();
        Update();
        icon.ForceCreate();
    }

    private static StatusViewModel State => App.Status;

    public void Dispose()
    {
        flyout.Close();
        icon.Dispose();
    }

    public void ShowNotification(string title, string message) => icon.ShowNotification(title, message, NotificationIcon.Warning);

    public void ClearNotifications() => icon.ClearNotifications();

    private void Update()
    {
        var status = State.CompactTitle;
        var hasProgress = State.HasProgress;
        title.Text = hasProgress ? string.Format(CultureInfo.CurrentCulture, Text.TrayStatusProgress, status, State.ProgressText) : status;
        lastBackup.Text = string.Format(CultureInfo.CurrentCulture, Text.TrayLastBackup, State.LastBackupText);
        nextBackup.Text = string.Format(CultureInfo.CurrentCulture, Text.TrayNextBackup, State.NextBackup);
        backUpOrCancel.Text = State.ShowsCancelAction ? Text.CommonCancel : Text.CommonBackUpNow;
        backUpOrCancel.IsEnabled = State.ShowsCancelAction || State.CanBackUp;
        icon.ToolTipText = hasProgress
            ? string.Format(CultureInfo.CurrentCulture, Text.TrayToolTipProgress, status, State.ProgressText)
            : string.Format(CultureInfo.CurrentCulture, Text.TrayToolTip, status);
    }
}
