using System.Runtime.InteropServices;

using FutoBackups.Core.Strings;
using FutoBackups.ViewModels;

using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Input;

using Windows.Foundation;
using Windows.Graphics;

namespace FutoBackups.Tray;

public sealed partial class TrayFlyout : Window
{
    private const double FlyoutWidth = 320;
    private const double EdgeMargin = 12;
    private static readonly TimeSpan ReopenGuard = TimeSpan.FromMilliseconds(300);

    private readonly Action open;

    public bool UpdatesAvailable => App.Updater.IsAvailable;
    private readonly Action quit;
    private DateTime hiddenAt = DateTime.MinValue;

    public TrayFlyout(Action open, Action quit)
    {
        this.open = open;
        this.quit = quit;
        InitializeComponent();
        Title = Text.CommonAppName;
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        AppWindow.SetPresenter(presenter);
        AppWindow.IsShownInSwitchers = false;
        AppWindow.Closing += (_, args) =>
        {
            args.Cancel = true;
            Dismiss();
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated)
            {
                Dismiss();
                return;
            }

            var first = BackUpButton.Visibility == Visibility.Visible && BackUpButton.IsEnabled ? BackUpButton : OpenButton;
            first.Focus(FocusState.Programmatic);
        };
        Root.SizeChanged += (_, args) =>
        {
            if (args.PreviousSize.Height != args.NewSize.Height)
            {
                Place();
            }
        };
    }

    public StatusViewModel Status => App.Status;

    public void Toggle()
    {
        if (AppWindow.IsVisible)
        {
            Dismiss();
            return;
        }

        if (DateTime.UtcNow - hiddenAt < ReopenGuard) return;
        Place();
        AppWindow.Show();
        Activate();
        SetForegroundWindow(Win32Interop.GetWindowFromWindowId(AppWindow.Id));
    }

    private void Place()
    {
        var scale = GetDpiForWindow(Win32Interop.GetWindowFromWindowId(AppWindow.Id)) / 96.0;
        Root.Width = FlyoutWidth;
        Root.Measure(new Size(FlyoutWidth, double.PositiveInfinity));
        var height = Root.ActualHeight > 0 ? Root.ActualHeight : Root.DesiredSize.Height;
        var frameWidth = AppWindow.Size.Width - AppWindow.ClientSize.Width;
        var frameHeight = AppWindow.Size.Height - AppWindow.ClientSize.Height;
        AppWindow.Resize(new SizeInt32((int)Math.Ceiling(FlyoutWidth * scale) + frameWidth, (int)Math.Ceiling(height * scale) + frameHeight));
        var area = DisplayArea.Primary.WorkArea;
        var margin = (int)Math.Round(EdgeMargin * scale);
        AppWindow.Move(new PointInt32(area.X + area.Width - AppWindow.Size.Width - margin, area.Y + area.Height - AppWindow.Size.Height - margin));
    }

    private void Dismiss()
    {
        if (!AppWindow.IsVisible) return;
        hiddenAt = DateTime.UtcNow;
        AppWindow.Hide();
    }

    private void Escape_Invoked(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        args.Handled = true;
        Dismiss();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        Dismiss();
        open();
        App.Status.CancelCommand.Execute(null);
    }

    private void Open_Click(object sender, RoutedEventArgs e)
    {
        Dismiss();
        open();
    }

    private void CheckForUpdates_Click(object sender, RoutedEventArgs e)
    {
        Dismiss();
        open();
        if (App.Window?.Content.XamlRoot is { } root)
        {
            _ = App.Updater.CheckNowAsync(root);
        }
    }

    private void Help_Click(object sender, RoutedEventArgs e)
    {
        Dismiss();
        Platform.FileExplorer.OpenUrl(Platform.FileExplorer.HelpUrl);
    }

    private void Quit_Click(object sender, RoutedEventArgs e) => quit();

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(nint window);
}
