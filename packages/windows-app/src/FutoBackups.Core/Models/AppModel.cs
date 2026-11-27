using System.Globalization;

using CommunityToolkit.Mvvm.ComponentModel;

using FutoBackups.Core;
using FutoBackups.Core.Api;
using FutoBackups.Core.Engine;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Status;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Models;

public abstract record LoginState
{
    public sealed record Idle : LoginState;

    public sealed record Waiting(string UserCode, Uri Url) : LoginState;

    public sealed record Finishing : LoginState;

    public sealed record Failed(string Message) : LoginState;
}

public enum SnapshotsLoad
{
    NotLoaded,
    Loading,
    Loaded,
    Failed,
}

public abstract record RecoveryKeyStep
{
    public sealed record Save : RecoveryKeyStep;

    public sealed record Confirm : RecoveryKeyStep;

    public sealed record ImportKey : RecoveryKeyStep;

    public sealed record ChooseRepository(IReadOnlyList<RemoteRepository> Repositories) : RecoveryKeyStep;

    public sealed record RepositoryKey(RemoteRepository Repository, IReadOnlyList<RemoteRepository> Among, bool StoredKeyFailed) : RecoveryKeyStep;

    public sealed record NewBackupKey(IReadOnlyList<RemoteRepository> Repositories) : RecoveryKeyStep;
}

public abstract record BackupDeletionState
{
    public sealed record Idle : BackupDeletionState;

    public sealed record Starting : BackupDeletionState;

    public sealed record ConfirmingInBrowser(Uri Url) : BackupDeletionState;

    public sealed record RemovingThisPc : BackupDeletionState;

    public sealed record PcStillLinked(IReadOnlyList<RemoteRepository> OtherRepositories, string? Detail) : BackupDeletionState;

    public sealed record Failed(string Message) : BackupDeletionState;

    public bool IsRunning => this is Starting or ConfirmingInBrowser or RemovingThisPc;
}

public sealed record Completion(string Title, string Message, StatusTint Tint);

public enum StartupReportState
{
    NotSent,
    Sending,
    Sent,
    NeedsSignIn,
    Failed,
}

public enum OwnerCheck
{
    Confirmed,
    Declined,
    Unavailable,
}

public abstract record KeyChange
{
    public sealed record Changed(KeyRotationOutcome Outcome) : KeyChange;

    public sealed record Declined : KeyChange;

    public sealed record Failed(string Message) : KeyChange;
}

public interface IPlatform
{
    string ComputerName { get; }

    string Home { get; }

    string AppVersion { get; }

    bool AllowsServerSelection { get; }

    void Post(Action action);

    Task OpenAsync(Uri url);

    void ShowFailureNotification(FailureNotice notice);

    void WithdrawFailureNotifications();

    bool LaunchAtLogin { get; set; }

    Task<OwnerCheck> ConfirmOwnerAsync(string message);

    MachineState Machine();

    IDisposable KeepAwake();

    event Action? MachineChanged;
}

public sealed partial class AppModel : ObservableObject, IDisposable
{
    private readonly IBackupEngine? engine;
    private readonly IAccountService account;
    private readonly ConfigStore store;
    private readonly LocalFiles files;
    private readonly IPlatform platform;
    private readonly string? missingHelperText;
    private bool configNeedsMovingAside;
    private readonly bool pinnedToProduction;
    private int sessionGeneration;
    private string? sessionToken;
    private CancellationTokenSource? operation;
    private Task? operationTask;

    public AppModel(IBackupEngine? engine, IAccountService account, ConfigStore store, LocalFiles files, IPlatform platform, string? missingHelperText)
    {
        this.engine = engine;
        this.account = account;
        this.store = store;
        this.files = files;
        this.platform = platform;
        this.missingHelperText = missingHelperText;
        platform.MachineChanged += () => platform.Post(() =>
        {
            Tick();
            OnPropertyChanged(nameof(AttachedUsbDevices));
        });
        var loaded = AppConfig.Defaults(platform.ComputerName, platform.Home);
        RunRecord? interruptedRun = null;
        try
        {
            loaded = store.Load(platform.ComputerName, platform.Home);
            loaded = loaded.AddingNewDefaultExcludes(platform.Home, out var added);
            if (!platform.AllowsServerSelection && !loaded.IsProductionServer)
            {
                loaded = loaded.SwitchingServer(AppConfig.ProductionServerUrl);
                pinnedToProduction = true;
                added = true;
            }

            if (loaded.ActiveRunStartedAt is { } interrupted)
            {
                loaded = loaded with
                {
                    ActiveRunStartedAt = null,
                    LastRun = new RunRecord { StartedAt = interrupted, FinishedAt = interrupted, Status = BackupStatus.Incomplete },
                    Runs = RunHistory.Adding(loaded.Runs, new RunEntry(RunKind.Backup, BackupStatus.Incomplete, interrupted, interrupted)),
                };
                interruptedRun = loaded.LastRun;
                added = true;
            }

            if (added)
            {
                store.Save(loaded);
            }
        }
        catch (Exception error)
        {
            ConfigLoadFailure = string.Format(CultureInfo.CurrentCulture, Text.ErrorCouldNotLoadSettings, error.Message);
            configNeedsMovingAside = true;
        }

        Config = loaded;
        if (interruptedRun is not null)
        {
            ShowCompletion(interruptedRun);
        }

        if (Config.OnboardingCompletedAt is null && Config.Folders.Count > 0)
        {
            UpdateConfig(config => config with { OnboardingCompletedAt = DateTimeOffset.Now });
        }

        RecomputeNextRun();
    }

    [ObservableProperty] public partial AppConfig Config { get; private set; }

    [ObservableProperty] public partial AuthInfo? Account { get; private set; }

    [ObservableProperty] public partial LoginState Login { get; private set; } = new LoginState.Idle();

    [ObservableProperty] public partial ActivityPhase? Activity { get; private set; }

    [ObservableProperty] public partial bool IsCancelling { get; private set; }

    [ObservableProperty] public partial IReadOnlyList<BackupCondition> WaitingFor { get; private set; } = [];

    [ObservableProperty] public partial BackupProgress? Progress { get; private set; }

    [ObservableProperty] public partial UploadSpeed? Speed { get; private set; }

    [ObservableProperty] public partial RestoreStep? Restore { get; private set; }

    [ObservableProperty] public partial IReadOnlyList<Snapshot> Snapshots { get; private set; } = [];

    [ObservableProperty] public partial SnapshotsLoad SnapshotsLoad { get; private set; }

    [ObservableProperty] public partial string? SnapshotsError { get; private set; }

    [ObservableProperty] public partial string? LastError { get; set; }

    [ObservableProperty] public partial DateTimeOffset? NextRun { get; private set; }

    [ObservableProperty] public partial bool SignedIn { get; private set; }

    [ObservableProperty] public partial bool HasSession { get; private set; }

    [ObservableProperty] public partial bool HasMasterKey { get; private set; }

    [ObservableProperty] public partial bool SessionLoaded { get; private set; }

    [ObservableProperty] public partial bool SessionExpired { get; private set; }

    [ObservableProperty] public partial string? ConfigLoadFailure { get; set; }

    [ObservableProperty] public partial RecoveryKeyStep? RecoveryKeyStep { get; private set; }

    [ObservableProperty] public partial IReadOnlyDictionary<string, StoredKeyCheck> EnteredKeyChecks { get; private set; } = new Dictionary<string, StoredKeyCheck>();

    [ObservableProperty] public partial IReadOnlyDictionary<string, StoredKeyCheck> StoredKeyChecks { get; private set; } = new Dictionary<string, StoredKeyCheck>();

    [ObservableProperty] public partial IReadOnlyList<string> RestoredFolders { get; set; } = [];

    [ObservableProperty] public partial bool RestoreStoppedEarly { get; private set; }

    [ObservableProperty] public partial BackupDeletionState BackupDeletion { get; private set; } = new BackupDeletionState.Idle();

    [ObservableProperty] public partial bool IsResetting { get; private set; }

    [ObservableProperty] public partial Completion? Completion { get; set; }

    [ObservableProperty] public partial long? RepositorySize { get; private set; }

    [ObservableProperty] public partial bool RepositorySizeEstimated { get; private set; }

    [ObservableProperty] public partial RemoteRepository? ThisRepository { get; private set; }

    [ObservableProperty] public partial bool WaitingForWriteOnceOff { get; private set; }

    [ObservableProperty] public partial IReadOnlyList<RemoteRepository> OtherDevices { get; private set; } = [];

    [ObservableProperty] public partial bool MissingOnService { get; private set; }

    [ObservableProperty] public partial int? AutomaticConnections { get; private set; }

    public string? MissingHelperText => missingHelperText;

    public string? StartupFailure => ConfigLoadFailure ?? missingHelperText;

    [ObservableProperty] public partial StartupReportState StartupReport { get; private set; }

    public string Home => platform.Home;

    public string AppVersion => platform.AppVersion;

    public bool AllowsServerSelection => platform.AllowsServerSelection;

    public bool IsMissingRecoveryKey => SignedIn && IsRecoveringLostKey;

    public bool IsRecoveringLostKey => Config.RepositoryId is not null && !HasMasterKey;

    public bool CanImportRecoveryKey => Config.RepositoryId is null || !HasMasterKey;

    public bool NeedsOnboarding => Core.Onboarding.OnboardingConfig.NeedsOnboarding(Config);

    public bool CanBackUpNow => SignedIn && Config.Folders.Count > 0 && Activity is null && operationTask is null && !IsResetting && !BackupDeletion.IsRunning && !IsMissingRecoveryKey && engine is not null;

    public bool CanCancelActivity => operationTask is not null && !IsCancelling && Activity?.IsCancellable() == true;

    public bool CanRestore => Activity is null && operationTask is null && SignedIn && !IsMissingRecoveryKey;

    public bool CanChangeRecoveryKey => engine is not null && SignedIn && HasMasterKey && Config.RepositoryId is not null && Activity is null && operationTask is null;

    private string BusyText => Activity switch
    {
        ActivityPhase.Restoring => Text.ErrorRestoreRunning,
        ActivityPhase.ChangingRecoveryKey => Text.ErrorKeyChangeRunning,
        null => Text.ErrorOperationRunning,
        _ => Text.ErrorBackupRunning,
    };

    public string ProtectedText => Snapshots is [{ TotalBytesProcessed: { } bytes }, ..] ? Format.Bytes(bytes) : "—";

    public StatusSummary Status => StatusSummary.For(new StatusInput(
        Activity, IsCancelling, Progress, Restore, Config.Folders, Config.LastRun, Config.SchedulePaused, SessionExpired, IsMissingRecoveryKey, ProtectedText, MissingOnService: MissingOnService, MissingHelper: engine is null ? missingHelperText ?? Text.ErrorMissingHelper : null, NextRun: NextRun));

    public IReadOnlyList<UsbDevice> AttachedUsbDevices => platform.Machine().UsbDevices;

    public string NextBackupText
    {
        get
        {
            if (Activity is not null) return Text.NextBackupRunningNow;
            if (Config.SchedulePaused) return Text.NextBackupPaused;
            if (WaitingFor.Count > 0) return BackupCondition.WaitingText(WaitingFor);
            if (NextRun is not { } next) return Text.ScheduleManual;
            return next <= DateTimeOffset.Now ? Text.NextBackupDueNow : Format.Relative(next);
        }
    }

    public async Task StartAsync()
    {
        if (pinnedToProduction)
        {
            try
            {
                account.Secrets.Delete(SecretKey.AccessToken);
            }
            catch (Exception)
            {
            }
        }

        sessionToken = configNeedsMovingAside || pinnedToProduction ? null : account.Secrets.Get(SecretKey.AccessToken);
        HasSession = sessionToken is not null;
        HasMasterKey = engine?.StoredMasterKey() is not null;
        SignedIn = HasSession && Config.RepositoryId is not null && Config.RecoveryKeyConfirmedAt is not null;
        if (HasSession && !SignedIn)
        {
            ContinueSetup();
        }

        SessionLoaded = true;
        if (HasSession)
        {
            await RefreshAccountAsync();
        }

        if (SignedIn)
        {
            await FinishPendingKeyRotationAsync();
            await RefreshSnapshotsAsync();
        }
    }

    public void Tick()
    {
        RecomputeNextRun();
        if (engine is null || Config.RepositoryId is null || Config.Folders.Count == 0 || operationTask is not null || Config.SchedulePaused)
        {
            ShowWaiting([]);
            return;
        }

        if (!HasSession || !SignedIn || IsMissingRecoveryKey)
        {
            ShowWaiting([]);
            BackupFailureReason? blocked = !HasSession ? BackupFailureReason.SignedOut : IsMissingRecoveryKey ? BackupFailureReason.MissingRecoveryKey : null;
            if (blocked is { } reason && Config.Schedule.IsDue(Config.ScheduleReference, DateTimeOffset.Now, TimeZoneInfo.Local))
            {
                AfterBackup(new BackupRunOutcome.Failed(reason), true);
            }

            return;
        }

        if (Config.ScheduleReference is null)
        {
            UpdateConfig(config => config with { ScheduleAnchor = DateTimeOffset.Now });
            RecomputeNextRun();
            ShowWaiting([]);
            return;
        }

        var decision = ScheduledRunDecision.For(Config, DateTimeOffset.Now, TimeZoneInfo.Local, platform.Machine);
        if (decision is ScheduledRunDecision.Wait wait)
        {
            RecordWaitingForConditions(true);
            ShowWaiting(wait.Unmet);
            return;
        }

        RecordWaitingForConditions(false);
        ShowWaiting([]);
        switch (decision)
        {
            case ScheduledRunDecision.Run:
                BackUpNow(true);
                break;
            case ScheduledRunDecision.RunAnyway runAnyway:
                Report("Running scheduled backup without its conditions", new() { ["unmet"] = runAnyway.Unmet.Select(condition => condition.TelemetryName).ToArray() });
                BackUpNow(true);
                break;
        }
    }

    private void ShowWaiting(IReadOnlyList<BackupCondition> conditions)
    {
        if (WaitingFor.SequenceEqual(conditions)) return;
        WaitingFor = conditions;
        OnPropertyChanged(nameof(NextBackupText));
    }

    private void RecordWaitingForConditions(bool waiting)
    {
        DateTimeOffset? since = waiting ? Config.WaitingForConditionsSince ?? DateTimeOffset.Now : null;
        if (Config.WaitingForConditionsSince == since) return;
        UpdateConfig(config => config with { WaitingForConditionsSince = since });
    }

    public void UpdateConfig(Func<AppConfig, AppConfig> change)
    {
        Config = change(Config);
        SaveConfig();
        OnPropertyChanged(nameof(Status));
    }

    private void SaveConfig()
    {
        try
        {
            if (configNeedsMovingAside)
            {
                if (store.MoveAside(DateTimeOffset.Now) is { } moved)
                {
                    ConfigLoadFailure = string.Format(CultureInfo.CurrentCulture, Text.ErrorKeptUnreadableFile, ConfigLoadFailure, Path.GetFileName(moved));
                }

                configNeedsMovingAside = false;
            }

            store.Save(Config);
        }
        catch (Exception error)
        {
            LastError = string.Format(CultureInfo.CurrentCulture, Text.ErrorCouldNotSaveSettings, error.Message);
        }
    }

    private void RecomputeNextRun()
    {
        NextRun = Config.SchedulePaused ? null : Config.Schedule.NextRun(Config.ScheduleReference, DateTimeOffset.Now, TimeZoneInfo.Local);
        OnPropertyChanged(nameof(NextBackupText));
    }

    private string? Message(Exception error)
    {
        if (ErrorMessage.SignsOut(error))
        {
            ExpireSession();
        }

        return ErrorMessage.Text(error, Config.ServerDisplayName);
    }

    private void ExpireSession()
    {
        if (!HasSession) return;
        SessionExpired = true;
        sessionToken = null;
        account.Secrets.Delete(SecretKey.AccessToken);
        HasSession = false;
        OnPropertyChanged(nameof(Status));
    }

    protected override void OnPropertyChanged(System.ComponentModel.PropertyChangedEventArgs e)
    {
        base.OnPropertyChanged(e);
        if (e.PropertyName is nameof(Activity) or nameof(Progress) or nameof(Restore) or nameof(IsCancelling) or nameof(Snapshots) or nameof(SignedIn) or nameof(HasMasterKey) or nameof(SessionExpired) or nameof(MissingOnService) or nameof(NextRun))
        {
            base.OnPropertyChanged(new System.ComponentModel.PropertyChangedEventArgs(nameof(Status)));
        }
    }

    public void ReportUnhandledError(Exception error, string source) => Report("Unhandled error", new() { ["source"] = source, ["error"] = error });

    internal void Report(string summary, Dictionary<string, object?>? data = null, bool force = false)
    {
        if ((!force && Config.TelemetryConsentedAt is null) || sessionToken is not { } token) return;
        var serverUrl = Config.ServerUrl;
        var log = new Telemetry().Log(summary, data ?? [], platform.AppVersion);
        _ = Task.Run(async () =>
        {
            try
            {
                await SubmitLogAsync(serverUrl, token, log);
            }
            catch (Exception)
            {
            }
        });
    }

    public async Task SendStartupReportAsync()
    {
        if (StartupFailure is not { } failure || StartupReport is StartupReportState.Sending or StartupReportState.Sent) return;
        if (sessionToken is not { } token)
        {
            StartupReport = StartupReportState.NeedsSignIn;
            return;
        }

        StartupReport = StartupReportState.Sending;
        try
        {
            await SubmitLogAsync(Config.ServerUrl, token, new Telemetry().Log("Bootstrap error", new Dictionary<string, object?> { ["error"] = failure, ["sentByUser"] = true }, platform.AppVersion));
            StartupReport = StartupReportState.Sent;
        }
        catch (Exception)
        {
            StartupReport = StartupReportState.Failed;
        }
    }

    private async Task SubmitLogAsync(Uri server, string token, StructuredLog log)
    {
        var client = await account.ClientAsync(server, token);
        await client.SubmitStructuredLogAsync(log);
    }

    private async Task RefreshAccountAsync()
    {
        var generation = sessionGeneration;
        try
        {
            var client = await account.ClientAsync(Config.ServerUrl, sessionToken);
            var info = await client.MeAsync();
            if (generation != sessionGeneration) return;
            Account = info;
            SessionExpired = false;
        }
        catch (Exception error)
        {
            if (generation != sessionGeneration) return;
            if (Message(error) is { } text && !SessionExpired)
            {
                LastError = text;
            }
        }
    }

    public async Task RefreshStorageAsync()
    {
        if (!SignedIn || Config.RepositoryId is not { } repositoryId || sessionToken is null) return;
        var generation = sessionGeneration;
        try
        {
            var server = await account.ResolveAsync(Config.ServerUrl);
            AutomaticConnections = Core.Engine.BackupEngine.ResolvedConnections(Config with { UploadConnections = null }, server, Environment.ProcessorCount);
            var client = await account.ClientAsync(Config.ServerUrl, sessionToken);
            var repositories = await client.ListRepositoriesAsync();
            if (generation != sessionGeneration || Config.RepositoryId != repositoryId) return;
            ThisRepository = repositories.FirstOrDefault(repository => repository.Id == repositoryId);
            if (ThisRepository is { } current && current.Worm != Config.IsWriteOnce)
            {
                UpdateConfig(config => config with { WriteOnce = current.Worm });
            }

            if (ThisRepository is { Worm: false })
            {
                WaitingForWriteOnceOff = false;
            }

            var measured = ThisRepository?.SizeBytes;
            OtherDevices = repositories.Where(repository => repository.Id != repositoryId).ToList();
            MissingOnService = repositories.All(repository => repository.Id != repositoryId);
            if (measured is > 0 || MissingOnService || engine is null || operationTask is not null)
            {
                RepositorySize = measured;
                RepositorySizeEstimated = false;
                return;
            }

            var estimate = await engine.RepositorySizeAsync(Config);
            if (generation != sessionGeneration || Config.RepositoryId != repositoryId) return;
            RepositorySize = estimate;
            RepositorySizeEstimated = estimate is not null;
        }
        catch (Exception error)
        {
            if (generation == sessionGeneration)
            {
                Message(error);
            }
        }
    }
}
