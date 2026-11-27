using System.ComponentModel;
using System.Globalization;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core;
using FutoBackups.Core.Models;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Pages.Settings;
using FutoBackups.Platform;

namespace FutoBackups.ViewModels;

public sealed partial class SettingsViewModel : ModelViewModel
{
    private static readonly int[] SupportRunChoices = [0, 1, 3, 5, 10, AppModel.MaxSupportRuns];

    private bool editingCustomRetention;

    public SettingsViewModel(AppModel model)
        : base(model)
    {
        Watch(App.Updater);
        Name = new TextSetting(() => Model.ThisRepository?.Name ?? Model.Config.Host, Model.RenameRepositoryAsync);
        Limit = new TextSetting(() => LimitText, text => Task.FromResult(ApplyLimit(text)));
        Retention = new RetentionEditor(() => Model.Config.SnapshotRetention, RequestRetentionAsync);
        editingCustomRetention = RetentionPresets.Matching(Model.Config.SnapshotRetention) is null;
    }

    public static IReadOnlyList<string> ParallelismLabels => [Text.SettingsAutomatic, .. AppConfig.ParallelismChoices.Select(choice => choice.ToString(CultureInfo.CurrentCulture))];

    public static IReadOnlyList<string> RetentionChoices => [.. RetentionPresets.All.Select(preset => preset.Label()), Text.SettingsRetentionCustom];

    public static IReadOnlyList<string> SupportRunLabels => SupportRunChoices.Select(runs => runs switch
    {
        0 => Text.SettingsSupportRunsOff,
        1 => Text.SettingsSupportOneRun,
        _ => string.Format(CultureInfo.CurrentCulture, Text.SettingsSupportRuns, runs),
    }).ToList();

    public static IReadOnlyList<string> RunAnywayLabels =>
        [Text.SettingsRunAnywayNever, .. BackupConditions.RunAnywayChoices.Select(days => days == 1 ? Text.SettingsRunAnywayOneDay : string.Format(CultureInfo.CurrentCulture, Text.SettingsRunAnywayDays, days))];

    public TextSetting Name { get; }

    public TextSetting Limit { get; }

    public RetentionEditor Retention { get; }

    public string Email => Model.Account?.Email ?? Text.SettingsSignedIn;

    public string Initials => Email[..1].ToUpperInvariant();

    public string ServerLine => $"{Model.Config.Host} · {Model.Config.ServerDisplayName}";

    public bool LaunchAtLogin
    {
        get => Model.LaunchAtLogin;
        set => Model.LaunchAtLogin = value;
    }

    public bool FailureNotifications
    {
        get => Model.Config.SendsFailureNotifications;
        set => Model.SetFailureNotifications(value);
    }

    public bool KeepAwake
    {
        get => Model.Config.KeepsAwake;
        set => Model.SetKeepAwake(value);
    }

    private BackupConditions Conditions => Model.Config.BackupConditions;

    public bool OnlyOnPower
    {
        get => Conditions.Power;
        set => Model.SetBackupConditions(Conditions with { Power = value });
    }

    public bool OnlyOnEthernet
    {
        get => Conditions.Ethernet;
        set => Model.SetBackupConditions(Conditions with { Ethernet = value });
    }

    public bool OnlyWithDisplay
    {
        get => Conditions.ExternalDisplay;
        set => Model.SetBackupConditions(Conditions with { ExternalDisplay = value });
    }

    private IReadOnlyList<UsbDevice> UsbDevices => UsbDeviceChoices.For(Conditions.UsbDevice, Model.AttachedUsbDevices);

    public IReadOnlyList<string> UsbLabels => [Text.SettingsUsbOff, .. UsbDevices.Select(device => UsbDeviceChoices.Label(device, UsbDevices, Model.AttachedUsbDevices))];

    public int UsbIndex
    {
        get => Conditions.UsbDevice is { } chosen ? UsbDevices.ToList().FindIndex(device => device.IsSameModel(chosen)) + 1 : 0;
        set
        {
            if (value < 0 || value == UsbIndex) return;
            Model.SetBackupConditions(Conditions with { UsbDevice = value == 0 ? null : UsbDevices[value - 1] });
        }
    }

    public bool ShowsRunAnyway => Conditions.Required.Count > 0;

    public int RunAnywayIndex
    {
        get => Conditions.RunAnywayAfterDays is { } days ? BackupConditions.RunAnywayChoices.ToList().IndexOf(days) + 1 : 0;
        set
        {
            if (value < 0 || value == RunAnywayIndex) return;
            Model.SetBackupConditions(Conditions with { RunAnywayAfterDays = value == 0 ? null : BackupConditions.RunAnywayChoices[value - 1] });
        }
    }

    public string WaitingText => Model.WaitingFor.Count > 0 ? BackupCondition.WaitingText(Model.WaitingFor) + "." : string.Empty;

    public bool IsWaiting => Model.WaitingFor.Count > 0;

    public string LimitText => UploadLimit.Text(Model.Config.Throttle.BytesPerSec);

    public bool HasUploadLimit => Model.Config.Throttle.BytesPerSec > 0;

    private QuietHours? Quiet => QuietHours.Parse(Model.Config.Throttle.QuietHours);

    public bool FullSpeedAtNight
    {
        get => Quiet is not null;
        set => QuietError = ApplyQuietHours(value, QuietStart, QuietEnd);
    }

    public bool ShowsQuietHours => HasUploadLimit && Quiet is not null;

    public TimeSpan QuietStart
    {
        get
        {
            var start = (Quiet ?? QuietHours.Default).Start;
            return new TimeSpan(start.Hour, start.Minute, 0);
        }

        set => QuietError = ApplyQuietHours(true, value, QuietEnd);
    }

    public TimeSpan QuietEnd
    {
        get
        {
            var end = (Quiet ?? QuietHours.Default).End;
            return new TimeSpan(end.Hour, end.Minute, 0);
        }

        set => QuietError = ApplyQuietHours(true, QuietStart, value);
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasQuietError))]
    public partial string? QuietError { get; private set; }

    public bool HasQuietError => QuietError is not null;

    public int RetentionIndex
    {
        get => !editingCustomRetention && RetentionPresets.Matching(Model.Config.SnapshotRetention) is { } preset
            ? Array.IndexOf(RetentionPresets.All, preset)
            : RetentionPresets.All.Length;
        set
        {
            if (value < 0 || value == RetentionIndex) return;
            editingCustomRetention = value == RetentionPresets.All.Length;
            if (editingCustomRetention)
            {
                NotifyChanges();
                return;
            }

            _ = RequestRetentionAsync(RetentionPresets.All[value].Retention());
        }
    }

    public bool IsEditingCustomRetention => RetentionIndex == RetentionPresets.All.Length;

    public string RetentionDescription => Model.Config.IsWriteOnce ? Text.SettingsRetentionWriteOnce : Model.Config.SnapshotRetention.Summary + ".";

    public bool CanChangeRetention => !Model.Config.IsWriteOnce;

    public bool IsWriteOnce
    {
        get => Model.Config.IsWriteOnce;
        set
        {
            if (value != Model.Config.IsWriteOnce)
            {
                _ = ChangeWriteOnceAsync(value);
            }
        }
    }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(WriteOnceText))]
    [NotifyPropertyChangedFor(nameof(HasWriteOnceText))]
    public partial string? WriteOnceError { get; private set; }

    public string WriteOnceText => Model.WaitingForWriteOnceOff ? Text.SettingsWriteOnceWaiting : WriteOnceError ?? string.Empty;

    public bool HasWriteOnceText => WriteOnceText.Length > 0;

    private int SupportRunsRemaining => Model.Config.SupportModeRunsRemaining ?? 0;

    public int SupportRunsIndex
    {
        get => Array.FindLastIndex(SupportRunChoices, runs => runs <= SupportRunsRemaining);
        set
        {
            if (value < 0 || value == SupportRunsIndex) return;
            Model.SetSupportMode(SupportRunChoices[value], SupportShares, SupportIncludesNames);
        }
    }

    public bool SupportIncludesNames
    {
        get => Model.Config.SupportModeIncludesPaths == true;
        set => Model.SetSupportMode(SupportRunsRemaining, SupportShares, value);
    }

    public bool SupportShares
    {
        get => Model.Config.SupportModeShareWithFuto == true;
        set => Model.SetSupportMode(SupportRunsRemaining, value, SupportIncludesNames);
    }

    public bool ShowsSupportNames => SupportRunsRemaining > 0;

    public bool ShowsSupportShare => SupportRunsRemaining > 0 && Model.Account?.StreamsSupportLogs == true;

    public IReadOnlyList<string> UploadLabels =>
        [Model.AutomaticConnections is { } automatic ? string.Format(CultureInfo.CurrentCulture, Text.SettingsAutomaticWith, automatic) : Text.SettingsAutomatic, .. ParallelismLabels.Skip(1)];

    public int UploadConnectionsIndex
    {
        get => IndexOf(Model.Config.UploadConnections);
        set
        {
            if (value >= 0 && value != UploadConnectionsIndex)
            {
                Model.SetUploadConnections(ChoiceAt(value));
            }
        }
    }

    public int ReadConcurrencyIndex
    {
        get => IndexOf(Model.Config.ReadConcurrency);
        set
        {
            if (value >= 0 && value != ReadConcurrencyIndex)
            {
                Model.SetReadConcurrency(ChoiceAt(value));
            }
        }
    }

    public string TelemetryStatus => Model.Config.TelemetryConsentedAt is { } at
        ? string.Format(CultureInfo.CurrentCulture, Text.SettingsTelemetryAgreed, Core.Util.Format.Absolute(at))
        : Text.SettingsTelemetry;

#if DEBUG
    private static string UnavailableVersionFormat => Text.SettingsVersionDevelopment;
#else
    private static string UnavailableVersionFormat => Text.SettingsVersion;
#endif

    public string VersionText => App.Updater switch
    {
        { IsAvailable: false } => string.Format(CultureInfo.CurrentCulture, UnavailableVersionFormat, Model.AppVersion),
        { ReadyVersion: { } ready } => string.Format(CultureInfo.CurrentCulture, Text.SettingsUpdateReady, ready),
        _ => string.Format(CultureInfo.CurrentCulture, Text.SettingsVersionUpdating, Model.AppVersion),
    };

    public bool UpdatesAvailable => App.Updater.IsAvailable;

    public bool UpdatesUnavailable => !UpdatesAvailable;

    public bool AutomaticUpdateChecks
    {
        get => Model.Config.AutomaticUpdateChecks == true;
        set => Model.SetAutomaticUpdateChecks(value);
    }

    public bool CanCheckForUpdates => !App.Updater.IsChecking;

    public bool CanChangeRecoveryKey => Model.CanChangeRecoveryKey;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(IsKeyRevealed))]
    [NotifyPropertyChangedFor(nameof(IsKeyHidden))]
    public partial string? RevealedKey { get; private set; }

    public bool IsKeyRevealed => RevealedKey is not null;

    public bool IsKeyHidden => RevealedKey is null;

    public bool AllowsServerSelection => Model.AllowsServerSelection;

    public bool IsResetting => Model.IsResetting;

    public bool IsNotResetting => !Model.IsResetting;

    public string StorageText => Model.RepositorySize is { } size
        ? string.Format(CultureInfo.CurrentCulture, Model.RepositorySizeEstimated ? Text.SettingsStoredOnEstimated : Text.SettingsStoredOnSized, Core.Util.Format.Bytes(size), Model.Config.ServerName())
        : string.Format(CultureInfo.CurrentCulture, Text.SettingsStoredOn, Model.Config.ServerName());

    public IReadOnlyList<RepositoryItem> OtherDevices => Model.OtherDevices.Select(repository => new RepositoryItem(repository, false, null)).ToList();

    public bool HasOtherDevices => Model.OtherDevices.Count > 0;

    public Uri AccountUrl => Model.Config.IsProductionServer ? new Uri("https://futo.cloud/") : new Uri(Model.Config.ServerUrl.GetLeftPart(UriPartial.Authority));

    public void HideRecoveryKey() => RevealedKey = null;

    protected override void OnModelChanged()
    {
        Name?.Refresh();
        Limit?.Refresh();
        if (RetentionPresets.Matching(Model.Config.SnapshotRetention) is not null || !editingCustomRetention)
        {
            Retention?.Load();
        }

        if (!Model.SignedIn || !Model.HasMasterKey)
        {
            HideRecoveryKey();
        }
    }

    protected override void OnPropertyChanged(PropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.PropertyName == nameof(UsbLabels))
        {
            OnPropertyChanged(nameof(UsbIndex));
        }
        else if (e.PropertyName == nameof(UploadLabels))
        {
            OnPropertyChanged(nameof(UploadConnectionsIndex));
        }
    }

    [RelayCommand]
    private async Task RevealRecoveryKeyAsync() => RevealedKey = await Model.RevealRecoveryKeyAsync();

    [RelayCommand]
    private async Task ChangeRecoveryKeyAsync()
    {
        await DialogHost.ShowAsync(new ChangeRecoveryKeyDialog());
        HideRecoveryKey();
    }

    [RelayCommand]
    private void OpenAccount() => FileExplorer.OpenUrl(AccountUrl);

    [RelayCommand]
    private static void OpenHelp() => FileExplorer.OpenUrl(FileExplorer.HelpUrl);

    [RelayCommand]
    private static void GetSupport() => FileExplorer.OpenUrl(FileExplorer.SupportUrl);

    [RelayCommand]
    private static void ReportIssue() => FileExplorer.OpenUrl(FileExplorer.IssuesUrl);

    [RelayCommand]
    private static Task CheckForUpdatesAsync() => App.Window?.Content.XamlRoot is { } root ? App.Updater.CheckNowAsync(root) : Task.CompletedTask;

    [RelayCommand]
    private static Task UnlinkAsync() => DialogHost.ShowAsync(new UnlinkDialog());

    [RelayCommand]
    private static Task DeleteBackupAsync() => DialogHost.ShowAsync(new DeleteBackupDialog());

    private string? ApplyLimit(string text)
    {
        try
        {
            Model.SetThrottle(Model.Config.Throttle with { BytesPerSec = UploadLimit.BytesPerSecond(text) });
            return null;
        }
        catch (UploadLimitException error)
        {
            return error.Message;
        }
    }

    private string? ApplyQuietHours(bool enabled, TimeSpan start, TimeSpan end)
    {
        if (!enabled)
        {
            Model.SetThrottle(Model.Config.Throttle with { QuietHours = string.Empty });
            return null;
        }

        try
        {
            var hours = new QuietHours(new ClockTime(start.Hours, start.Minutes), new ClockTime(end.Hours, end.Minutes));
            Model.SetThrottle(Model.Config.Throttle with { QuietHours = hours.Text });
            return null;
        }
        catch (QuietHoursException error)
        {
            return error.Message;
        }
    }

    private async Task RequestRetentionAsync(SnapshotRetention retention)
    {
        if (retention == Model.Config.SnapshotRetention) return;
        if (retention.MayDeleteMoreThan(Model.Config.SnapshotRetention))
        {
            var confirmed = await DialogHost.ConfirmAsync(
                Text.SettingsDeleteMoreTitle,
                string.Format(CultureInfo.CurrentCulture, Text.SettingsDeleteMoreBody, retention.Summary),
                Text.SettingsDeleteOldSnapshotsButton,
                Text.CommonCancel);
            if (!confirmed)
            {
                OnPropertyChanged(nameof(RetentionIndex));
                return;
            }
        }

        Model.SetRetention(retention);
    }

    private async Task ChangeWriteOnceAsync(bool on)
    {
        WriteOnceError = null;
        if (on)
        {
            var confirmed = await DialogHost.ConfirmAsync(Text.SettingsWriteOnceConfirmTitle, Text.SettingsWriteOnceConfirmBody, Text.SettingsWriteOnceTurnOn, Text.CommonCancel);
            WriteOnceError = confirmed ? await Model.EnableWriteOnceAsync() : null;
        }
        else
        {
            WriteOnceError = await Model.DisableWriteOnceAsync();
        }

        OnPropertyChanged(nameof(IsWriteOnce));
    }

    private static int IndexOf(int? choice) => choice is { } value ? Array.IndexOf(AppConfig.ParallelismChoices, value) + 1 : 0;

    private static int? ChoiceAt(int index) => index <= 0 ? null : AppConfig.ParallelismChoices[index - 1];
}
