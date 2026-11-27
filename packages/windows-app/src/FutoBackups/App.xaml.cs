using System.Globalization;

using FutoBackups.Core.Api;
using FutoBackups.Core.Engine;
using FutoBackups.Core.Models;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Mock;
using FutoBackups.Platform;
using FutoBackups.ResticWrapper;
using FutoBackups.Tray;
using FutoBackups.ViewModels;
using FutoBackups.YuccaApi;

using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;

namespace FutoBackups;

public partial class App : Application
{
    private const string MockArgument = "--mock";

    private static readonly string CrashLog = Path.Combine(Path.GetTempPath(), "FUTO Backups crash.log");

    private readonly string[] arguments;
    private TrayIcon? tray;
    private WindowsPlatform? platform;
    private DispatcherQueueTimer? scheduler;

    public App(string[] arguments)
    {
        this.arguments = arguments;
        InitializeComponent();
        UnhandledException += (_, args) =>
        {
            File.AppendAllText(CrashLog, $"{DateTimeOffset.Now:O} {args.Exception}\n\n");
            args.Handled = true;
            Model.LastError = string.Format(CultureInfo.CurrentCulture, Text.ErrorRanIntoProblem, args.Message);
            Model.ReportUnhandledError(args.Exception, "ui");
        };
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            args.SetObserved();
            Model?.ReportUnhandledError(args.Exception.GetBaseException(), "task");
        };
#if DEBUG
        AppDomain.CurrentDomain.FirstChanceException += (_, args) =>
        {
            if (args.Exception is System.Runtime.InteropServices.COMException or InvalidOperationException)
            {
                File.AppendAllText(CrashLog, $"{DateTimeOffset.Now:O} first chance {args.Exception}\n\n");
            }
        };
#endif
    }

    public static MainWindow? Window { get; private set; }

    public static AppModel Model { get; private set; } = null!;

    public static StatusViewModel Status { get; private set; } = null!;

    public static Updater Updater { get; private set; } = null!;

    public static void Quit()
    {
        var app = (App)Current;
        app.QuitApp();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        AppNotificationManager.Default.NotificationInvoked += (_, _) => dispatcher.TryEnqueue(() => Window?.ShowFromTray());
        if (AppNotificationManager.IsSupported())
        {
            AppNotificationManager.Default.Register();
        }

        AppInstance.GetCurrent().Activated += (_, _) => dispatcher.TryEnqueue(() => Window?.ShowFromTray());
        platform = new WindowsPlatform(dispatcher, () => Window is null ? 0 : WinRT.Interop.WindowNative.GetWindowHandle(Window));
        Model = arguments.Contains(MockArgument) ? MockServices.Model(platform) : RealModel(platform);
        Status = new StatusViewModel(Model);
        Updater = new Updater(Model);
        Window = new MainWindow();
        tray = new TrayIcon(Window.ShowFromTray, QuitApp);
        platform.Tray = tray;
        if (!arguments.Contains(WindowsPlatform.BackgroundArgument))
        {
            Window.Activate();
        }

        scheduler = dispatcher.CreateTimer();
        scheduler.Interval = TimeSpan.FromSeconds(60);
        scheduler.Tick += (_, _) => Model.Tick();
        scheduler.Start();
        Updater.StartBackgroundChecks(dispatcher);
        _ = StartAsync();
    }

    private static async Task StartAsync()
    {
        await Model.StartAsync();
        Model.Tick();
    }

    private static AppModel RealModel(WindowsPlatform platform)
    {
        var secrets = new CredentialManagerSecretStore();
        var discovery = new Discovery(new HttpClient { Timeout = TimeSpan.FromSeconds(8) });
        var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        var account = new AccountService(discovery, http, secrets, platform.OpenAsync);
        var restic = HelperLocator.Locate(Helper.Restic);
        var proxy = HelperLocator.Locate(Helper.ResticProxy);
        IBackupEngine? engine = null;
        string? missing = null;
        if (restic is not null && proxy is not null)
        {
            var cache = Path.Combine(LocalFiles.Standard().CacheDirectory, "restic");
            Directory.CreateDirectory(cache);
            engine = new BackupEngine(new EngineEnvironment(
                secrets,
                discovery.ResolveAsync,
                (apiRoot, token) => new YuccaClient(apiRoot, http, token),
                new ResticRunner(restic),
                new ResticProxyLauncher(proxy),
                cache,
                Environment.ProcessorCount,
                () => DateTimeOffset.Now)
            {
                AppVersion = platform.AppVersion,
                CloudOnlyScanner = new PlaceholderScanner(),
            });
        }
        else
        {
            var absent = restic is null ? Helper.Restic : Helper.ResticProxy;
            missing = string.Format(CultureInfo.CurrentCulture, Text.ErrorMissingHelperNamed, absent.FileName());
        }

        return new AppModel(engine, account, ConfigStore.Standard(), LocalFiles.Standard(), platform, missing);
    }

    private void QuitApp()
    {
        scheduler?.Stop();
        tray?.Dispose();
        Model.Cancel();
        Model.Dispose();
        platform?.Dispose();
        Window?.Quit();
        Exit();
    }
}
