using System.Globalization;
using System.Reflection;

using FutoBackups.Core;
using FutoBackups.Core.Models;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;

using Microsoft.UI.Dispatching;
using Microsoft.Win32;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

using Windows.Security.Credentials.UI;

namespace FutoBackups.Platform;

public sealed class WindowsPlatform(DispatcherQueue dispatcher, Func<nint> windowHandle) : IPlatform, IDisposable
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string RunValue = "FUTO Backups";

    private readonly MachineProbe probe = new();

    public void Dispose() => probe.Dispose();

    public const string BackgroundArgument = "--background";

    public string ComputerName => Environment.MachineName;

    public string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public string AppVersion { get; } =
        Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "dev";

#if DEBUG
    public bool AllowsServerSelection => true;
#else
    public bool AllowsServerSelection => Environment.GetEnvironmentVariable("FUTO_BACKUPS_SERVER_SELECTION") == "1";
#endif

    public void Post(Action action) => dispatcher.TryEnqueue(() => action());

    public Task OpenAsync(Uri url)
    {
        FileExplorer.OpenUrl(url);
        return Task.CompletedTask;
    }

    public Tray.TrayIcon? Tray { get; set; }

    public MachineState Machine() => probe.Current();

    public IDisposable KeepAwake() => MachineProbe.KeepAwake();

    public event Action? MachineChanged
    {
        add => probe.Changed += value;
        remove => probe.Changed -= value;
    }

    public void ShowFailureNotification(FailureNotice notice)
    {
        if (!AppNotificationManager.IsSupported())
        {
            Tray?.ShowNotification(notice.Title, notice.Body);
            return;
        }

        var notification = new AppNotificationBuilder().AddText(notice.Title).AddText(notice.Body).BuildNotification();
        notification.Tag = "failure";
        AppNotificationManager.Default.Show(notification);
    }

    public void WithdrawFailureNotifications()
    {
        if (!AppNotificationManager.IsSupported())
        {
            Tray?.ClearNotifications();
            return;
        }

        _ = AppNotificationManager.Default.RemoveByTagAsync("failure");
    }

    public bool LaunchAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(RunValue) is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value)
            {
                key.SetValue(RunValue, $"\"{Environment.ProcessPath}\" {BackgroundArgument}");
            }
            else
            {
                key.DeleteValue(RunValue, false);
            }
        }
    }

    public async Task<OwnerCheck> ConfirmOwnerAsync(string message)
    {
        var availability = await UserConsentVerifier.CheckAvailabilityAsync();
        if (availability != UserConsentVerifierAvailability.Available) return WindowsPassword.Confirm(windowHandle(), message);
        var result = await UserConsentVerifierInterop.RequestVerificationForWindowAsync(windowHandle(), message);
        return result switch
        {
            UserConsentVerificationResult.Verified => OwnerCheck.Confirmed,
            UserConsentVerificationResult.Canceled or UserConsentVerificationResult.RetriesExhausted => OwnerCheck.Declined,
            _ => WindowsPassword.Confirm(windowHandle(), message),
        };
    }
}
