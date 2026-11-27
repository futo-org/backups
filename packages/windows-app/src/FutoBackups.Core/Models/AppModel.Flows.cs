using System.Globalization;

using FutoBackups.Core;
using FutoBackups.Core.Api;
using FutoBackups.Core.Engine;
using FutoBackups.Core.Onboarding;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Status;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Support;
using FutoBackups.Core.Util;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Models;

public sealed partial class AppModel
{
    private static string SetupIncomplete => Text.ErrorSetupIncomplete;
    private static string OwnerUnavailableMessage => Text.ErrorOwnerUnavailable;

    private CancellationTokenSource? login;
    private int loginGeneration;
    private int onboardingGeneration;
    private string? pendingRecoveryKey;
    private bool pendingRecoveryKeyConfirmed;
    private CancellationTokenSource? storedKeyChecks;
    private Task? storedKeyCheckTask;
    private Task storedKeyChecksSettled = Task.CompletedTask;
    private CancellationTokenSource? backupDeletion;

    private enum UnlockKind
    {
        Finished,
        Failed,
        Superseded,
    }

    private sealed record UnlockAttempt(UnlockKind Kind, ExistingBackupUnlock Unlock = ExistingBackupUnlock.WrongKey, string? Message = null);

    public async Task StartLoginAsync()
    {
        if (login is not null) return;
        if (engine is null)
        {
            Login = new LoginState.Failed(missingHelperText ?? SetupIncomplete);
            return;
        }

        if (HasSession && !SignedIn && Login is LoginState.Failed)
        {
            ContinueSetup();
            return;
        }

        var generation = ++loginGeneration;
        var cancellation = login = new CancellationTokenSource();
        try
        {
            var server = Config.ServerUrl;
            var authorization = await account.StartDeviceAuthorizationAsync(server, cancellation.Token);
            if (generation != loginGeneration) return;
            var url = new Uri(authorization.VerificationUriComplete ?? authorization.VerificationUri);
            Login = new LoginState.Waiting(authorization.UserCode, url);
            await platform.OpenAsync(url);
            var token = await account.WaitForTokenAsync(server, authorization, Config.Host, cancellation.Token);
            if (generation != loginGeneration) return;
            account.Secrets.Set(SecretKey.AccessToken, token);
            sessionToken = token;
            HasSession = true;
            SessionExpired = false;
            LastError = null;
            Login = new LoginState.Finishing();
            var client = await account.ClientAsync(server, token, cancellation.Token);
            Account = await client.MeAsync(cancellation.Token);
            if (generation != loginGeneration) return;
            if (Config.RepositoryId is { } repositoryId)
            {
                var repositories = await client.ListRepositoriesAsync(cancellation.Token);
                if (generation != loginGeneration) return;
                MissingOnService = repositories.All(repository => repository.Id != repositoryId);
            }

            Report("Connected FUTO Backups backend", new() { ["backendId"] = Telemetry.FutoCloudBackendId });
            if (missingHelperText is not null)
            {
                Report("Bootstrap error", new() { ["error"] = missingHelperText }, force: true);
            }

            login = null;
            Login = new LoginState.Idle();
            if (SignedIn)
            {
                if (!MissingOnService)
                {
                    await RefreshSnapshotsAsync();
                }

                return;
            }

            ContinueSetup();
        }
        catch (Exception error)
        {
            if (generation != loginGeneration) return;
            login = null;
            var text = Message(error);
            Login = text is null ? new LoginState.Idle() : new LoginState.Failed(text);
            if (SignedIn && text is not null)
            {
                LastError = text;
            }
        }
    }

    public void CancelLogin()
    {
        if (login is not { } running) return;
        loginGeneration++;
        login = null;
        running.Cancel();
        Login = new LoginState.Idle();
    }

    public void DismissRecoveryKeyEntry()
    {
        if (SignedIn && RecoveryKeyStep is RecoveryKeyStep.ImportKey)
        {
            RecoveryKeyStep = null;
        }
    }

    public void ShowRecoveryKeyStep(RecoveryKeyStep step)
    {
        if (step is RecoveryKeyStep.ImportKey && !IsRecoveringLostKey) return;
        onboardingGeneration++;
        switch (step)
        {
            case RecoveryKeyStep.ChooseRepository choose:
                StartStoredKeyChecks(choose.Repositories);
                break;
            case RecoveryKeyStep.Save or RecoveryKeyStep.Confirm or RecoveryKeyStep.ImportKey:
                HoldRecoveryKey(null);
                break;
        }

        RecoveryKeyStep = step;
    }

    public async Task<string?> ShowExistingBackupsAsync()
    {
        var generation = ++onboardingGeneration;
        if (!CanImportRecoveryKey) return Text.ErrorAlreadyHasRecoveryKey;
        if (engine is null) return missingHelperText ?? SetupIncomplete;
        try
        {
            var repositories = await engine.WindowsRepositoriesAsync(Config);
            var storedKey = HasMasterKey ? engine.StoredMasterKey() : null;
            if (generation != onboardingGeneration || !HasSession) return null;
            if (repositories.Count == 0)
            {
                HoldRecoveryKey(null);
                ShowRecoveryKeyStep(new RecoveryKeyStep.NewBackupKey([]));
                return null;
            }

            HoldRecoveryKey(storedKey);
            ShowRecoveryKeyStep(new RecoveryKeyStep.ChooseRepository(repositories));
            return null;
        }
        catch (Exception error)
        {
            if (generation != onboardingGeneration || !HasSession) return null;
            return Message(error);
        }
    }

    public string? RecoveryKey()
    {
        if (engine is null) return null;
        try
        {
            return Config.RepositoryId is not null ? engine.StoredMasterKey() : engine.MasterKey();
        }
        catch (Exception)
        {
            return null;
        }
    }

    public async Task<string?> RevealRecoveryKeyAsync()
    {
        var check = await platform.ConfirmOwnerAsync(Text.KeyWantsToShow);
        if (check == OwnerCheck.Unavailable)
        {
            LastError = OwnerUnavailableMessage;
        }

        return check == OwnerCheck.Confirmed ? RecoveryKey() : null;
    }

    public bool ConfirmRecoveryKey(string input)
    {
        onboardingGeneration++;
        if (RecoveryKey() is not { } key || !HasSession) return false;
        if (!RepositoryKeys.Matches(input, key)) return false;
        HasMasterKey = true;
        MarkRecoveryKeyConfirmed();
        return true;
    }

    public async Task<string?> ImportRecoveryKeyAsync(string input)
    {
        if (!IsRecoveringLostKey || Config.RepositoryId is not { } repositoryId) return Text.ErrorAlreadyHasRecoveryKey;
        if (RepositoryKeys.NormalizedMasterKey(input) is not { } normalized) return Text.ErrorInvalidRecoveryKey;
        var attempt = await UnlockRepositoryAsync(repositoryId, normalized, false);
        switch (attempt.Kind)
        {
            case UnlockKind.Superseded:
                return null;
            case UnlockKind.Failed:
                return attempt.Message;
            case UnlockKind.Finished when attempt.Unlock == ExistingBackupUnlock.Unlocked:
                HasMasterKey = true;
                if (SignedIn)
                {
                    LastError = null;
                    RecoveryKeyStep = null;
                    await RefreshSnapshotsAsync();
                }
                else
                {
                    MarkRecoveryKeyConfirmed();
                }

                return null;
            default:
                return Text.ErrorKeyDoesNotOpenBackup;
        }
    }

    public async Task<string?> ChooseRepositoryAsync(RemoteRepository repository, IReadOnlyList<RemoteRepository> among)
    {
        if (pendingRecoveryKey is not { } storedKey)
        {
            ShowRecoveryKeyStep(new RecoveryKeyStep.RepositoryKey(repository, among, false));
            return null;
        }

        var attempt = await UnlockRepositoryAsync(repository.Id, storedKey, true);
        switch (attempt.Kind)
        {
            case UnlockKind.Superseded:
                return null;
            case UnlockKind.Failed:
                StartStoredKeyChecks(among);
                return attempt.Message;
            case UnlockKind.Finished when attempt.Unlock == ExistingBackupUnlock.Unlocked:
                await ContinueRepositoryAsync(repository);
                return null;
            default:
                ShowRecoveryKeyStep(new RecoveryKeyStep.RepositoryKey(repository, among, true));
                return null;
        }
    }

    public async Task<string?> EnterRepositoryKeyAsync(string input, RemoteRepository repository)
    {
        if (RepositoryKeys.NormalizedMasterKey(input) is not { } normalized) return Text.ErrorInvalidRecoveryKey;
        EnteredKeyChecks = new Dictionary<string, StoredKeyCheck>();
        var attempt = await UnlockRepositoryAsync(repository.Id, normalized, false);
        switch (attempt.Kind)
        {
            case UnlockKind.Superseded:
                return null;
            case UnlockKind.Failed:
                SetEnteredKeyCheck(repository.Id, StoredKeyCheck.Unknown);
                return attempt.Message;
            case UnlockKind.Finished when attempt.Unlock == ExistingBackupUnlock.Unlocked:
                await ContinueRepositoryAsync(repository);
                return null;
            default:
                SetEnteredKeyCheck(repository.Id, StoredKeyCheck.DoesNotOpen);
                if (RecoveryKeyStep is RecoveryKeyStep.RepositoryKey step)
                {
                    StartKeyChecks(normalized, step.Among.Where(other => other.Id != repository.Id).Select(other => other.Id).ToList(), SetEnteredKeyCheck);
                }

                return string.Format(CultureInfo.CurrentCulture, Text.ErrorKeyDoesNotOpenRepository, repository.Name);
        }
    }

    public async Task<string?> StartNewBackupAsync(IReadOnlyList<RemoteRepository> insteadOf)
    {
        var generation = ++onboardingGeneration;
        if (engine is null) return missingHelperText ?? SetupIncomplete;
        if (pendingRecoveryKey is not { } key || !pendingRecoveryKeyConfirmed)
        {
            ShowRecoveryKeyStep(new RecoveryKeyStep.NewBackupKey(insteadOf));
            return null;
        }

        return await ImportKeyAndStartAsync(key, generation);
    }

    public async Task<string?> StartNewBackupWithKeyAsync(string input)
    {
        var generation = ++onboardingGeneration;
        if (Config.RepositoryId is not null) return Text.ErrorAlreadyHasBackup;
        if (engine is null) return missingHelperText ?? SetupIncomplete;
        return await ImportKeyAndStartAsync(input, generation);
    }

    private async Task<string?> ImportKeyAndStartAsync(string key, int generation)
    {
        await StopStoredKeyChecksAsync();
        if (generation != onboardingGeneration || !HasSession) return null;
        try
        {
            engine!.ImportMasterKey(key);
        }
        catch (Exception error)
        {
            return Message(error);
        }

        HasMasterKey = true;
        HoldRecoveryKey(null);
        MarkRecoveryKeyConfirmed(false);
        return null;
    }

    private async Task<UnlockAttempt> UnlockRepositoryAsync(string repositoryId, string key, bool isStored)
    {
        var generation = ++onboardingGeneration;
        if (engine is null) return new UnlockAttempt(UnlockKind.Failed, Message: missingHelperText ?? SetupIncomplete);
        await StopStoredKeyChecksAsync();
        if (generation != onboardingGeneration || !HasSession) return new UnlockAttempt(UnlockKind.Superseded);
        Report("Running repository import", new() { ["repositoryId"] = repositoryId });
        try
        {
            var unlock = await engine.UnlockExistingRepositoryAsync(repositoryId, key, isStored, Config);
            if (generation != onboardingGeneration || !HasSession) return new UnlockAttempt(UnlockKind.Superseded);
            if (isStored)
            {
                SetStoredKeyCheck(repositoryId, unlock == ExistingBackupUnlock.Unlocked ? StoredKeyCheck.Opens : StoredKeyCheck.DoesNotOpen);
            }

            Report("Finished repository import", unlock == ExistingBackupUnlock.Unlocked
                ? new() { ["repositoryId"] = repositoryId }
                : new() { ["repositoryId"] = repositoryId, ["error"] = "wrong recovery key" });
            return new UnlockAttempt(UnlockKind.Finished, unlock);
        }
        catch (Exception error)
        {
            if (generation != onboardingGeneration || !HasSession) return new UnlockAttempt(UnlockKind.Superseded);
            Report("Finished repository import", new() { ["repositoryId"] = repositoryId, ["error"] = error });
            return Message(error) is { } text ? new UnlockAttempt(UnlockKind.Failed, Message: text) : new UnlockAttempt(UnlockKind.Superseded);
        }
    }

    private async Task ContinueRepositoryAsync(RemoteRepository repository)
    {
        HasMasterKey = true;
        HoldRecoveryKey(null);
        UpdateConfig(config => config with { RepositoryId = repository.Id, RecoveryKeyConfirmedAt = DateTimeOffset.Now });
        RecoveryKeyStep = null;
        SignedIn = true;
        RecomputeNextRun();
        await RefreshSnapshotsAsync();
        if (Config.Folders.Count == 0 && Snapshots.MaxBy(snapshot => snapshot.Time) is { } latest)
        {
            var previous = latest.Paths.Where(path => Directory.Exists(path) || File.Exists(path)).ToList();
            if (previous.Count > 0)
            {
                UpdateConfig(config => config.CompletingOnboarding(previous, DateTimeOffset.Now));
                ReportRepositoryChange();
            }
        }
    }

    private void HoldRecoveryKey(string? key, bool confirmed = false)
    {
        pendingRecoveryKeyConfirmed = key is not null && confirmed;
        if (key is not null && key == pendingRecoveryKey) return;
        storedKeyChecks?.Cancel();
        storedKeyChecks = null;
        storedKeyCheckTask = null;
        StoredKeyChecks = new Dictionary<string, StoredKeyCheck>();
        pendingRecoveryKey = key;
    }

    private void SetStoredKeyCheck(string repositoryId, StoredKeyCheck check) =>
        StoredKeyChecks = new Dictionary<string, StoredKeyCheck>(StoredKeyChecks) { [repositoryId] = check };

    private void SetEnteredKeyCheck(string repositoryId, StoredKeyCheck check) =>
        EnteredKeyChecks = new Dictionary<string, StoredKeyCheck>(EnteredKeyChecks) { [repositoryId] = check };

    private void StartStoredKeyChecks(IReadOnlyList<RemoteRepository> repositories)
    {
        if (pendingRecoveryKey is not { } storedKey || storedKeyCheckTask is not null) return;
        var unchecked_ = repositories.Select(repository => repository.Id)
            .Where(id => !StoredKeyChecks.TryGetValue(id, out var check) || check == StoredKeyCheck.Unknown).ToList();
        StartKeyChecks(storedKey, unchecked_, SetStoredKeyCheck);
    }

    private void StartKeyChecks(string key, IReadOnlyList<string> repositoryIds, Action<string, StoredKeyCheck> record)
    {
        if (engine is null || repositoryIds.Count == 0) return;
        storedKeyChecks?.Cancel();
        var previous = storedKeyChecksSettled;
        var cancellation = storedKeyChecks = new CancellationTokenSource();
        storedKeyChecksSettled = storedKeyCheckTask = Task.Run(async () =>
        {
            await previous;
            try
            {
                await engine.CheckKeyAsync(key, repositoryIds, Config, (id, check) => platform.Post(() =>
                {
                    if (!cancellation.IsCancellationRequested)
                    {
                        record(id, check);
                    }
                }), cancellation.Token);
            }
            catch (Exception)
            {
            }

            platform.Post(() =>
            {
                if (storedKeyChecks == cancellation)
                {
                    storedKeyChecks = null;
                    storedKeyCheckTask = null;
                }
            });
        });
    }

    private async Task StopStoredKeyChecksAsync()
    {
        storedKeyChecks?.Cancel();
        storedKeyChecks = null;
        storedKeyCheckTask = null;
        await storedKeyChecksSettled;
        StoredKeyChecks = StoredKeyChecks.Where(pair => pair.Value != StoredKeyCheck.Checking).ToDictionary();
        EnteredKeyChecks = EnteredKeyChecks.Where(pair => pair.Value != StoredKeyCheck.Checking).ToDictionary();
    }

    private void MarkRecoveryKeyConfirmed(bool offeringExistingRepositories = true)
    {
        UpdateConfig(config => config with { RecoveryKeyConfirmedAt = DateTimeOffset.Now });
        ContinueSetup(offeringExistingRepositories);
    }

    public void ContinueSetup(bool offeringExistingRepositories = true)
    {
        if (IsRecoveringLostKey)
        {
            RecoveryKeyStep = new RecoveryKeyStep.ImportKey();
            return;
        }

        if (Config.RepositoryId is null && !HasMasterKey)
        {
            UpdateConfig(config => config with { RecoveryKeyConfirmedAt = null });
            RecoveryKeyStep = new RecoveryKeyStep.Save();
            return;
        }

        if (Config.RecoveryKeyConfirmedAt is null)
        {
            RecoveryKeyStep = new RecoveryKeyStep.Save();
            return;
        }

        RecoveryKeyStep = null;
        if (engine is null)
        {
            Login = new LoginState.Failed(missingHelperText ?? SetupIncomplete);
            return;
        }

        Login = new LoginState.Finishing();
        _ = SetUpRepositoryAsync(offeringExistingRepositories, loginGeneration);
    }

    private async Task SetUpRepositoryAsync(bool offeringExisting, int generation)
    {
        var cancellation = login = new CancellationTokenSource();
        try
        {
            var setup = await engine!.SetUpRepositoryAsync(Config, offeringExisting, cancellation.Token);
            if (generation != loginGeneration) return;
            login = null;
            Login = new LoginState.Idle();
            switch (setup)
            {
                case RepositorySetup.ChooseExisting existing:
                    HoldRecoveryKey(existing.MasterKey, true);
                    ShowRecoveryKeyStep(new RecoveryKeyStep.ChooseRepository(existing.Repositories));
                    break;
                case RepositorySetup.Ready ready:
                    UpdateConfig(config => config with { RepositoryId = ready.RepositoryId });
                    SignedIn = true;
                    RecomputeNextRun();
                    await RefreshSnapshotsAsync();
                    break;
            }
        }
        catch (Exception error)
        {
            if (generation != loginGeneration) return;
            login = null;
            if (error is EngineException { Error: EngineError.MissingMasterKey })
            {
                HasMasterKey = false;
                UpdateConfig(config => config with { RecoveryKeyConfirmedAt = null });
                RecoveryKeyStep = new RecoveryKeyStep.Save();
                Login = new LoginState.Idle();
                return;
            }

            Login = Message(error) is { } text ? new LoginState.Failed(text) : new LoginState.Idle();
        }
    }

    public void Logout()
    {
        var serverUrl = Config.ServerUrl;
        var token = sessionToken;
        sessionToken = null;
        sessionGeneration++;
        onboardingGeneration++;
        operation?.Cancel();
        Account = null;
        Snapshots = [];
        SnapshotsLoad = SnapshotsLoad.NotLoaded;
        SignedIn = false;
        HasSession = false;
        MissingOnService = false;
        SessionExpired = false;
        RestoredFolders = [];
        RecoveryKeyStep = null;
        HoldRecoveryKey(null);
        loginGeneration++;
        login?.Cancel();
        login = null;
        Login = new LoginState.Idle();
        if (Config.ActiveRunStartedAt is not null)
        {
            UpdateConfig(config => config with { ActiveRunStartedAt = null });
        }

        if (token is null) return;
        try
        {
            account.Secrets.Delete(SecretKey.AccessToken);
        }
        catch (Exception)
        {
            LastError = Text.ErrorCouldNotRemoveSignIn;
        }

        _ = Task.Run(async () =>
        {
            try
            {
                var client = await account.ClientAsync(serverUrl, token);
                await client.LogoutAsync();
            }
            catch (Exception)
            {
            }
        });
    }

    public void FinishOnboarding(IReadOnlyList<string> folders, RetentionPreset retention, bool backUpNow)
    {
        UpdateConfig(config => config.CompletingOnboarding(folders, DateTimeOffset.Now) with { Retention = retention.Retention() });
        RecomputeNextRun();
        ReportRepositoryChange();
        if (backUpNow)
        {
            BackUpNow();
        }
    }

    public void StartReplacementBackup()
    {
        if (!MissingOnService || engine is null || operationTask is not null) return;
        MissingOnService = false;
        SignedIn = false;
        Snapshots = [];
        UpdateConfig(config => config with { RepositoryId = null, LastRun = null, ScheduleAnchor = DateTimeOffset.Now });
        Login = new LoginState.Finishing();
        _ = SetUpRepositoryAsync(false, loginGeneration);
    }

    public void BackUpNow(bool scheduled = false)
    {
        if (Activity is not null || operationTask is not null || IsResetting || backupDeletion is not null) return;
        string? refusal = null;
        if (engine is null)
        {
            refusal = missingHelperText;
        }
        else if (!HasSession)
        {
            refusal = Text.CommonNotSignedIn;
        }
        else if (!SignedIn)
        {
            refusal = Text.ErrorFinishSetupFirst;
        }
        else if (IsMissingRecoveryKey)
        {
            refusal = Message(new EngineException(EngineError.MissingMasterKey));
        }
        else if (Config.RepositoryId is null)
        {
            refusal = Text.ErrorNoRepositoryYet;
        }
        else if (Config.Folders.Count == 0)
        {
            refusal = Text.ErrorNoFoldersSelected;
        }

        if (refusal is not null || engine is null)
        {
            LastError = refusal;
            return;
        }

        var snapshot = Config;
        var generation = sessionGeneration;
        Activity = ActivityPhase.Preparing;
        LastError = null;
        UpdateConfig(config => config with { ActiveRunStartedAt = DateTimeOffset.Now });
        if (scheduled)
        {
            Report("Running schedule for 1 repositories", new() { ["lastRun"] = DateTimeOffset.Now, ["repositories"] = new[] { snapshot.RepositoryId } });
        }

        StartOperation(cancellation => RunBackupAsync(engine, snapshot, generation, scheduled, cancellation));
    }

    private async Task RunBackupAsync(IBackupEngine engine, AppConfig snapshot, int generation, bool scheduled, CancellationToken cancellation)
    {
        var started = DateTimeOffset.Now;
        using var wakeLock = snapshot.KeepsAwake ? platform.KeepAwake() : null;
        var supportLog = await StartSupportLogAsync(snapshot, "backup", started, cancellation);
        if (supportLog is not null)
        {
            UpdateConfig(config => config with { SupportModeRunsRemaining = config.SupportModeRunsRemaining is > 1 ? config.SupportModeRunsRemaining - 1 : null });
        }

        try
        {
            try
            {
                await engine.FinishPendingKeyRotationAsync(snapshot, cancellation);
            }
            catch (Exception error) when (!ErrorMessage.IsCancellation(error))
            {
            }

            var record = await engine.BackupAsync(snapshot, activity => platform.Post(() => Show(activity, generation)), supportLog, cancellation);
            FinishOperation();
            if (generation != sessionGeneration) return;
            if (supportLog is not null)
            {
                await supportLog.DisposeAsync();
            }

            UpdateConfig(config => config with { LastRun = record, ActiveRunStartedAt = null, Runs = RunHistory.Adding(config.Runs, new RunEntry(RunKind.Backup, record.Status, record.StartedAt, record.FinishedAt, record.Message, supportLog?.Path, supportLog?.Code)) });
            if (record.Status is BackupStatus.Failed)
            {
                if (BackupFailureReasons.FromMessage(record.Message) == BackupFailureReason.SignedOut)
                {
                    await RefreshAccountAsync();
                }
            }

            RecomputeNextRun();
            AfterBackup(BackupRunOutcome.From(record), scheduled);
            ShowCompletion(record);

            await RefreshSnapshotsAsync();
        }
        catch (Exception error)
        {
            FinishOperation();
            if (generation != sessionGeneration) return;
            if (error is EngineException { Error: EngineError.MissingMasterKey })
            {
                HasMasterKey = false;
            }

            var text = Message(error);
            var status = ErrorMessage.IsCancellation(error) ? BackupStatus.Cancelled : BackupStatus.Failed;
            if (supportLog is not null)
            {
                await supportLog.DisposeAsync();
            }

            var finished = DateTimeOffset.Now;
            var failed = new RunRecord { StartedAt = started, FinishedAt = finished, Status = status, Message = text };
            UpdateConfig(config => config with
            {
                ActiveRunStartedAt = null,
                LastRun = failed,
                Runs = RunHistory.Adding(config.Runs, new RunEntry(RunKind.Backup, status, started, finished, text, supportLog?.Path, supportLog?.Code)),
            });
            AfterBackup(BackupRunOutcome.From(error), scheduled);
            ShowCompletion(failed);
        }
        finally
        {
            if (scheduled)
            {
                Report("Finished running schedule for 1 repositories", new() { ["lastFinished"] = DateTimeOffset.Now });
            }
        }
    }

    private void ShowCompletion(RunRecord record)
    {
        var added = record.DataAdded is { } bytes ? string.Format(CultureInfo.CurrentCulture, Text.StatusDataAdded, Format.Bytes(bytes)) : null;
        var files = record.FilesNew is { } count ? Format.Count(count, Text.StatusOneNewFile, Text.StatusNewFiles) : null;
        var items = record.FilesProcessed is { } total ? Format.Count(total, Text.StatusOneItem, Text.StatusItems) : null;
        var processed = record.BytesProcessed is { } size ? Format.Bytes(size) : null;
        var detail = string.Join(" · ", new[] { items, processed, files, added }.OfType<string>());
        Completion = record.Status switch
        {
            BackupStatus.Warn => new Completion(Text.StatusBackedUpWithWarnings, record.Message ?? Text.StatusCouldNotReadSome, StatusTint.Caution),
            BackupStatus.Failed => new Completion(Text.StatusLastBackupFailed, record.Message ?? Text.StatusCheckConnection, StatusTint.Critical),
            BackupStatus.Cancelled => new Completion(Text.StatusBackupCancelled, Text.RunCancelledMessage, StatusTint.Neutral),
            BackupStatus.Incomplete => new Completion(Text.StatusBackupInterrupted, Text.RunInterruptedMessage, StatusTint.Caution),
            _ => new Completion(Text.RunBackupComplete, record.Message ?? (detail.Length > 0 ? detail : Text.StatusNoChanges), record.Message is null ? StatusTint.Success : StatusTint.Caution),
        };
    }

    private void AfterBackup(BackupRunOutcome outcome, bool scheduled)
    {
        switch (FailureNoticeStep.After(outcome, scheduled, Config.SendsFailureNotifications, Config.FailureNotifiedAt is not null, false))
        {
            case FailureNoticeStep.Post post:
                platform.ShowFailureNotification(FailureNotice.For(post.Reason, Config.ServerName(), NextRun, DateTimeOffset.Now));
                UpdateConfig(config => config with { FailureNotifiedAt = DateTimeOffset.Now });
                break;
            case FailureNoticeStep.EndStreak:
                platform.WithdrawFailureNotifications();
                UpdateConfig(config => config with { FailureNotifiedAt = null });
                break;
        }
    }

    public void Cancel()
    {
        if (operation is not { } running || Activity?.IsCancellable() == false) return;
        IsCancelling = true;
        running.Cancel();
        NotifyOperationChanged();
    }

    public void Dispose()
    {
        foreach (var source in new[] { operation, login, storedKeyChecks, backupDeletion })
        {
            source?.Dispose();
        }
    }

    public void RestoreSnapshot(Snapshot snapshot, string target) =>
        StartRestore((engine, config, onActivity, support, cancellation) =>
            engine.RestoreAsync(config, snapshot.Id, RestorePlan.Items(snapshot.Paths, target), onActivity, support, cancellation));

    public void RestoreSelection(Snapshot snapshot, IReadOnlyList<SnapshotEntry> selection, string target) =>
        StartRestore((engine, config, onActivity, support, cancellation) =>
            engine.RestoreAsync(config, snapshot.Id, selection, target, onActivity, support, cancellation));

    private void StartRestore(Func<IBackupEngine, AppConfig, Action<EngineActivity>, ISupportLogSink?, CancellationToken, Task<IReadOnlyList<string>>> run)
    {
        string? refusal = null;
        if (Activity is not null || operationTask is not null)
        {
            refusal = BusyText;
        }
        else if (engine is null)
        {
            refusal = missingHelperText;
        }
        else if (!SignedIn)
        {
            refusal = Text.ErrorFinishSetupFirst;
        }
        else if (IsMissingRecoveryKey)
        {
            refusal = Message(new EngineException(EngineError.MissingMasterKey));
        }
        else if (Config.RepositoryId is null)
        {
            refusal = Text.ErrorNoRepositoryYet;
        }

        if (refusal is not null || engine is null)
        {
            LastError = refusal;
            return;
        }

        var snapshot = Config;
        var generation = sessionGeneration;
        Activity = ActivityPhase.Restoring;
        RestoredFolders = [];
        StartOperation(cancellation => RunRestoreAsync(engine, snapshot, generation, run, cancellation));
    }

    private async Task RunRestoreAsync(IBackupEngine engine, AppConfig snapshot, int generation, Func<IBackupEngine, AppConfig, Action<EngineActivity>, ISupportLogSink?, CancellationToken, Task<IReadOnlyList<string>>> run, CancellationToken cancellation)
    {
        var started = DateTimeOffset.Now;
        SupportLog? supportLog = null;
        IReadOnlyList<string> restored = [];
        var stoppedEarly = false;
        string? message = null;
        BackupStatus status;
        try
        {
            supportLog = await StartSupportLogAsync(snapshot, "restore", started, cancellation);
            restored = await run(engine, snapshot, activity => platform.Post(() => Show(activity, generation)), supportLog, cancellation);
            status = BackupStatus.Complete;
        }
        catch (RestoreIncompleteException incomplete)
        {
            stoppedEarly = true;
            restored = incomplete.Restored;
            message = Message(incomplete);
            status = ErrorMessage.IsCancellation(incomplete.Cause) ? BackupStatus.Cancelled : BackupStatus.Incomplete;
        }
        catch (Exception error)
        {
            message = Message(error);
            status = ErrorMessage.IsCancellation(error) ? BackupStatus.Cancelled : BackupStatus.Failed;
        }

        if (supportLog is not null)
        {
            await supportLog.DisposeAsync();
        }

        if (generation == sessionGeneration)
        {
            RestoreStoppedEarly = stoppedEarly;
            RestoredFolders = restored;
            if (message is not null)
            {
                LastError = message;
            }

            UpdateConfig(config => config with { Runs = RunHistory.Adding(config.Runs, new RunEntry(RunKind.Restore, status, started, DateTimeOffset.Now, message, supportLog?.Path, supportLog?.Code)) });
        }

        FinishOperation();
    }

    private async Task<SupportLog?> StartSupportLogAsync(AppConfig snapshot, string jobName, DateTimeOffset started, CancellationToken cancellation)
    {
        if (snapshot.SupportModeRunsRemaining is not > 0) return null;
        SupportLogUploader? stream = null;
        if (snapshot.SupportModeShareWithFuto == true && Account?.StreamsSupportLogs == true && sessionToken is { } token)
        {
            try
            {
                var client = await account.ClientAsync(snapshot.ServerUrl, token, cancellation);
                var session = await client.CreateSupportSessionAsync(Guid.NewGuid().ToString(), jobName, snapshot.SupportModeIncludesPaths == true, platform.AppVersion, cancellation);
                stream = new SupportLogUploader(client, session);
            }
            catch (Exception error) when (!ErrorMessage.IsCancellation(error))
            {
                Report("Failed to start support log streaming", new() { ["error"] = error });
            }
        }

        var logPath = Path.Combine(files.SupportLogDirectory, $"{started.ToLocalTime():yyyyMMdd-HHmmss}-{jobName}.ndjson");
        return new SupportLog(logPath, snapshot.SupportModeIncludesPaths == true ? null : new PathRedactor(), stream, () => DateTimeOffset.Now);
    }

    public Task<IReadOnlyList<SnapshotEntry>> ListDirectoryAsync(Snapshot snapshot, string path, CancellationToken cancellation)
    {
        if (engine is null) throw new InvalidOperationException(missingHelperText ?? SetupIncomplete);
        return engine.ListDirectoryAsync(Config, snapshot.Id, path, cancellation);
    }

    public string Describe(Exception error) => Message(error) ?? error.Message;

    public async Task RefreshSnapshotsAsync()
    {
        if (Config.RepositoryId is null) return;
        if (engine is null)
        {
            SnapshotsLoad = SnapshotsLoad.Failed;
            SnapshotsError = missingHelperText ?? SetupIncomplete;
            return;
        }

        var generation = sessionGeneration;
        var previous = SnapshotsLoad;
        SnapshotsLoad = SnapshotsLoad.Loading;
        try
        {
            var result = await engine.SnapshotsAsync(Config);
            if (generation != sessionGeneration) return;
            Snapshots = result;
            SnapshotsLoad = SnapshotsLoad.Loaded;
            SnapshotsError = null;
        }
        catch (Exception error)
        {
            if (generation != sessionGeneration) return;
            if (Message(error) is not { } text)
            {
                SnapshotsLoad = previous;
                return;
            }

            SnapshotsLoad = SnapshotsLoad.Failed;
            SnapshotsError = text;
            LastError = text;
        }

        _ = RefreshStorageAsync();
    }

    public async Task<KeyChange> ChangeRecoveryKeyAsync(string newKey)
    {
        if (engine is null) return new KeyChange.Failed(missingHelperText ?? SetupIncomplete);
        if (!CanChangeRecoveryKey) return new KeyChange.Failed(BusyText);
        var check = await platform.ConfirmOwnerAsync(Text.KeyWantsToChange);
        if (check == OwnerCheck.Declined) return new KeyChange.Declined();
        if (check == OwnerCheck.Unavailable) return new KeyChange.Failed(OwnerUnavailableMessage);
        if (!CanChangeRecoveryKey) return new KeyChange.Failed(BusyText);
        var snapshot = Config;
        var generation = sessionGeneration;
        Activity = ActivityPhase.ChangingRecoveryKey;
        var change = Task.Run(() => engine.ChangeMasterKeyAsync(newKey, snapshot));
        operationTask = change;
        NotifyOperationChanged();
        try
        {
            var outcome = await change;
            FinishOperation();
            if (generation == sessionGeneration)
            {
                HasMasterKey = true;
                UpdateConfig(config => config with { RecoveryKeyConfirmedAt = DateTimeOffset.Now });
            }

            return new KeyChange.Changed(outcome);
        }
        catch (Exception error)
        {
            FinishOperation();
            return new KeyChange.Failed(error switch
            {
                KeyRotationException { Error: KeyRotationError.CurrentKeyNotFound } => Text.ErrorKeyNotFoundInBackup,
                KeyRotationException { Error: KeyRotationError.NewKeyRejected } => Text.ErrorKeyNotAccepted,
                KeyRotationException { Error: KeyRotationError.PasswordFileFailed } => Text.ErrorKeyPrepareFailed,
                KeyRotationException => Text.ErrorKeyEarlierChange,
                _ => Message(error) ?? Text.ErrorKeyChangeCancelled,
            });
        }
    }

    private async Task FinishPendingKeyRotationAsync()
    {
        if (engine is null || operationTask is not null) return;
        var generation = sessionGeneration;
        try
        {
            await engine.FinishPendingKeyRotationAsync(Config);
        }
        catch (Exception)
        {
        }

        if (generation != sessionGeneration || HasMasterKey) return;
        if (engine.StoredMasterKey() is not null)
        {
            HasMasterKey = true;
        }
    }

    public void StartBackupDeletion()
    {
        if (backupDeletion is not null || IsResetting || Config.RepositoryId is not { } repositoryId) return;
        BackupDeletion = new BackupDeletionState.Starting();
        var cancellation = backupDeletion = new CancellationTokenSource();
        _ = RunBackupDeletionAsync(repositoryId, cancellation);
    }

    private async Task RunBackupDeletionAsync(string repositoryId, CancellationTokenSource cancellation)
    {
        await StopRunningWorkAsync();
        try
        {
            var api = await account.ClientAsync(Config.ServerUrl, sessionToken, cancellation.Token);
            var telemetry = Config.TelemetryConsentedAt is not null ? new Telemetry() : null;
            var deletion = new Core.Engine.BackupDeletion(api, platform.OpenAsync, telemetry, platform.AppVersion);
            var result = await deletion.RunAsync(repositoryId, step =>
            {
                platform.Post(() =>
                {
                    if (backupDeletion != cancellation) return;
                    BackupDeletion = step switch
                    {
                        BackupDeletionStep.ConfirmingInBrowser confirming => new BackupDeletionState.ConfirmingInBrowser(confirming.Url),
                        _ => new BackupDeletionState.RemovingThisPc(),
                    };
                });
                return Task.CompletedTask;
            }, cancellation.Token);
            backupDeletion = null;
            switch (result)
            {
                case BackupDeletionResult.ConnectionKeepsRepositories keeps:
                    BackupDeletion = new BackupDeletionState.PcStillLinked(keeps.Repositories, null);
                    break;
                default:
                    await ResetLocallyAsync(false);
                    break;
            }
        }
        catch (Exception error)
        {
            backupDeletion = null;
            BackupDeletion = error switch
            {
                OperationCanceledException => new BackupDeletionState.Idle(),
                BackupDeletionException { Error: BackupDeletionError.ConnectionNotDeleted or BackupDeletionError.ConnectionUnreachable } deletion => new BackupDeletionState.PcStillLinked([], deletion.Detail),
                BackupDeletionException => new BackupDeletionState.Failed(error.Message),
                YuccaApiException { StatusCode: 401 } => new BackupDeletionState.Failed(Text.ErrorDeleteSessionExpired),
                _ => Message(error) is { } text ? new BackupDeletionState.Failed(text) : new BackupDeletionState.Idle(),
            };
        }
    }

    public void CancelBackupDeletion() => backupDeletion?.Cancel();

    public void DismissBackupDeletion()
    {
        if (backupDeletion is null)
        {
            BackupDeletion = new BackupDeletionState.Idle();
        }
    }

    public async Task ResetThisPcAsync()
    {
        if (IsResetting || backupDeletion is not null) return;
        await ResetLocallyAsync(true);
    }

    private async Task StopRunningWorkAsync()
    {
        loginGeneration++;
        login?.Cancel();
        login = null;
        var running = operationTask;
        operation?.Cancel();
        if (running is null) return;
        try
        {
            await running;
        }
        catch (Exception)
        {
        }
    }

    private async Task ResetLocallyAsync(bool signingOut)
    {
        IsResetting = true;
        platform.WithdrawFailureNotifications();
        await StopRunningWorkAsync();
        IAccountApi? api = null;
        if (signingOut && sessionToken is { } token)
        {
            try
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(8));
                api = await account.ClientAsync(Config.ServerUrl, token, deadline.Token);
            }
            catch (Exception)
            {
            }
        }

        StructuredLog? log = null;
        if (Config.TelemetryConsentedAt is not null)
        {
            log = new Telemetry().Log("Unlink this PC", Config.RepositoryId is { } id ? new Dictionary<string, object?> { ["repositoryId"] = id } : [], platform.AppVersion);
        }

        var failed = await new PcReset(files, account.Secrets).RunAsync(api, log);
        ReturnToFirstScreen();
        if (failed.Count > 0)
        {
            ConfigLoadFailure = string.Format(CultureInfo.CurrentCulture, Text.ErrorCouldNotRemoveEverything, string.Join(", ", failed.Select(item => item.Title())));
        }

        IsResetting = false;
    }

    private void ReturnToFirstScreen()
    {
        sessionToken = null;
        sessionGeneration++;
        onboardingGeneration++;
        loginGeneration++;
        Config = AppConfig.Defaults(platform.ComputerName, platform.Home);
        Account = null;
        Login = new LoginState.Idle();
        FinishOperation();
        Snapshots = [];
        SnapshotsLoad = SnapshotsLoad.NotLoaded;
        LastError = null;
        SignedIn = false;
        HasSession = false;
        HasMasterKey = false;
        SessionExpired = false;
        RestoredFolders = [];
        RecoveryKeyStep = null;
        HoldRecoveryKey(null);
        ConfigLoadFailure = null;
        configNeedsMovingAside = false;
        BackupDeletion = new BackupDeletionState.Idle();
        RepositorySize = null;
        RepositorySizeEstimated = false;
        OtherDevices = [];
        MissingOnService = false;
        RecomputeNextRun();
    }

    private void StartOperation(Func<CancellationToken, Task> run)
    {
        var cancellation = operation = new CancellationTokenSource();
        var start = new Task<Task>(() => run(cancellation.Token));
        operationTask = start.Unwrap();
        NotifyOperationChanged();
        start.RunSynchronously();
    }

    private void FinishOperation()
    {
        Activity = null;
        Progress = null;
        Speed = null;
        Restore = null;
        operation = null;
        operationTask = null;
        IsCancelling = false;
        NotifyOperationChanged();
    }

    private void NotifyOperationChanged()
    {
        OnPropertyChanged(nameof(CanBackUpNow));
        OnPropertyChanged(nameof(CanCancelActivity));
        OnPropertyChanged(nameof(CanRestore));
        OnPropertyChanged(nameof(CanChangeRecoveryKey));
        OnPropertyChanged(nameof(NextBackupText));
    }

    private void Show(EngineActivity activity, int generation)
    {
        if (operationTask is null || generation != sessionGeneration) return;
        var phase = activity.Phase();
        if (Activity != phase)
        {
            Activity = phase;
        }

        switch (activity)
        {
            case EngineActivity.BackingUp backingUp:
                Progress = backingUp.Progress;
                Speed = backingUp.Speed;
                break;
            case EngineActivity.Restoring restoring:
                Restore = restoring.Step;
                Speed = null;
                break;
            default:
                Speed = null;
                break;
        }
    }

    private void ReportRepositoryChange()
    {
        if (Config.RepositoryId is not { } repositoryId) return;
        Report("Updated repository", new() { ["repositoryId"] = repositoryId, ["pathCount"] = Config.Folders.Count });
    }
}
