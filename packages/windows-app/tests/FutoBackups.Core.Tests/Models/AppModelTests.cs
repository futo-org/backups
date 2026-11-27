using System.ComponentModel;
using System.Globalization;

using FutoBackups.Core.Api;
using FutoBackups.Core.Engine;
using FutoBackups.Core.Models;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Status;
using FutoBackups.Core.Support;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Tests.Models;

public class AppModelTests
{
    private const string RepositoryId = "repo-1";

    private sealed class Engine : IBackupEngine
    {
        public Func<CancellationToken, Task<RunRecord>> Backup { get; set; } = _ => Task.FromResult(new RunRecord { Status = BackupStatus.Complete });

        public Func<Task<IReadOnlyList<string>>> Restore { get; set; } = () => Task.FromResult<IReadOnlyList<string>>([]);

        public Func<Task<KeyRotationOutcome>> ChangeKey { get; set; } = () => Task.FromResult(KeyRotationOutcome.Complete);

        public int KeyChanges { get; private set; }

        public bool IsRunning => false;

        public string MasterKey() => EngineFixture.MasterKey;

        public string? StoredKey { get; set; } = EngineFixture.MasterKey;

        public string? StoredMasterKey() => StoredKey;

        public void ImportMasterKey(string input) => throw new NotSupportedException();

        public int SetUps { get; private set; }

        public Func<Task<RepositorySetup>> SetUp { get; set; } =
            () => Task.FromException<RepositorySetup>(new HttpRequestException("server error", null, System.Net.HttpStatusCode.InternalServerError));

        public TaskCompletionSource KeyCheckStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource KeyCheckReleased { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        private bool checkingKey;

        public Task<RepositorySetup> SetUpRepositoryAsync(AppConfig config, bool offeringExisting, CancellationToken cancellation = default)
        {
            SetUps++;
            return SetUp();
        }

        public ISupportLogSink? Support { get; private set; }

        public Task<RunRecord> BackupAsync(AppConfig config, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default)
        {
            Support = support;
            support?.Add("stdout", "backup", @"open C:\Users\test\Documents\taxes.pdf");
            return Backup(cancellation);
        }

        public IReadOnlyList<Snapshot> SnapshotList { get; set; } = [];

        public Task<IReadOnlyList<Snapshot>> SnapshotsAsync(AppConfig config, CancellationToken cancellation = default) => Task.FromResult(SnapshotList);

        public Task<IReadOnlyList<SnapshotEntry>> ListDirectoryAsync(AppConfig config, string snapshotId, string path, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<IReadOnlyList<string>> RestoreAsync(AppConfig config, string snapshotId, IReadOnlyList<RestoreItem> items, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default) => Restoring(support);

        public Task<IReadOnlyList<string>> RestoreAsync(AppConfig config, string snapshotId, IReadOnlyList<SnapshotEntry> selection, string target, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default) => Restoring(support);

        private Task<IReadOnlyList<string>> Restoring(ISupportLogSink? support)
        {
            Support = support;
            support?.Add("stdout", "restore", @"restored C:\Users\test\Documents\taxes.pdf");
            return Restore();
        }

        public Task<IReadOnlyList<RemoteRepository>> WindowsRepositoriesAsync(AppConfig config, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<IReadOnlyList<RemoteRepository>> OtherRepositoriesAsync(AppConfig config, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Func<string, string, bool>? KeyOpens { get; set; }

        public TaskCompletionSource KeyChecksDone { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public Task<ExistingBackupUnlock> UnlockExistingRepositoryAsync(string repositoryId, string key, bool isStored, AppConfig config, CancellationToken cancellation = default)
        {
            if (KeyOpens is { } opens) return Task.FromResult(opens(repositoryId, key) ? ExistingBackupUnlock.Unlocked : ExistingBackupUnlock.WrongKey);
            return checkingKey ? throw new EngineException(EngineError.Busy) : Task.FromResult(ExistingBackupUnlock.Unlocked);
        }

        public async Task CheckKeyAsync(string key, IReadOnlyList<string> repositoryIds, AppConfig config, Action<string, StoredKeyCheck> onCheck, CancellationToken cancellation = default)
        {
            if (KeyOpens is { } opens)
            {
                foreach (var id in repositoryIds)
                {
                    onCheck(id, opens(id, key) ? StoredKeyCheck.Opens : StoredKeyCheck.DoesNotOpen);
                }

                if (key != EngineFixture.MasterKey)
                {
                    KeyChecksDone.TrySetResult();
                }

                return;
            }

            checkingKey = true;
            KeyCheckStarted.TrySetResult();
            try
            {
                await Task.Delay(Timeout.Infinite, cancellation);
            }
            catch (OperationCanceledException)
            {
            }

            await KeyCheckReleased.Task;
            checkingKey = false;
        }

        public Task<KeyRotationOutcome> ChangeMasterKeyAsync(string input, AppConfig config, CancellationToken cancellation = default)
        {
            KeyChanges++;
            return ChangeKey();
        }

        public Task<bool> FinishPendingKeyRotationAsync(AppConfig config, CancellationToken cancellation = default) => Task.FromResult(false);

        public long? LocalSize { get; set; }

        public Task<long?> RepositorySizeAsync(AppConfig config, CancellationToken cancellation = default) => Task.FromResult(LocalSize);

        public Task UpdateThrottleAsync(Throttle throttle) => Task.CompletedTask;
    }

    private sealed class RefusingDeleteStore(ISecretStore inner) : ISecretStore
    {
        public string? Get(SecretKey key) => inner.Get(key);

        public void Set(SecretKey key, string value) => inner.Set(key, value);

        public void Delete(SecretKey key) => throw new Win32Exception(5);
    }

    private sealed class Account(ISecretStore secrets) : IAccountService, IAccountApi
    {
        public Func<Task<IReadOnlyList<RemoteRepository>>> Repositories { get; set; } =
            () => Task.FromResult<IReadOnlyList<RemoteRepository>>([new RemoteRepository(RepositoryId, "test-pc", false, "connection-1")]);

        public ISecretStore Secrets { get; } = secrets;

        public Task<ServerInfo> ResolveAsync(Uri server, CancellationToken cancellation = default) => Task.FromResult(new ServerInfo(new Uri("https://api.example/")));

        public Task<DeviceAuthorization> StartDeviceAuthorizationAsync(Uri server, CancellationToken cancellation = default) =>
            Task.FromResult(new DeviceAuthorization("device", "BXKR-TQLM", "https://futo.cloud/device", null, 900, 5));

        public Task<string> WaitForTokenAsync(Uri server, DeviceAuthorization authorization, string connectionName, CancellationToken cancellation = default) => Task.FromResult("token");

        public Task<IAccountApi> ClientAsync(Uri server, string? token, CancellationToken cancellation = default) => Task.FromResult<IAccountApi>(this);

        public Task OpenBrowserAsync(Uri url) => Task.CompletedTask;

        public Func<Task<AuthInfo>> Me { get; set; } = () => Task.FromResult(new AuthInfo("user-1", "Sam", "sam@example.com", "connection-1"));

        public Task<AuthInfo> MeAsync(CancellationToken cancellation = default) => Me();

        public Task LogoutAsync(CancellationToken cancellation = default) => Task.CompletedTask;

        public Task<IReadOnlyList<RemoteRepository>> ListRepositoriesAsync(CancellationToken cancellation = default) => Repositories();

        public List<(string Action, string RepositoryId)> Tickets { get; } = [];

        public List<(string? Name, bool? Worm)> Updates { get; } = [];

        public Task<RemoteRepository> UpdateRepositoryAsync(string repositoryId, string? name = null, bool? worm = null, CancellationToken cancellation = default)
        {
            Updates.Add((name, worm));
            return Task.FromResult(new RemoteRepository(repositoryId, name ?? "test-pc", worm ?? false, "connection-1"));
        }

        public Task<Uri> CreateTicketAsync(string action, string repositoryId, CancellationToken cancellation = default)
        {
            Tickets.Add((action, repositoryId));
            return Task.FromResult(new Uri("https://futo.cloud/ticket"));
        }

        public Task DeleteConnectionAsync(string id, CancellationToken cancellation = default) => throw new NotSupportedException();

        public List<string> SupportBatches { get; } = [];

        public Task<SupportSession> CreateSupportSessionAsync(string jobId, string jobName, bool includesPaths, string clientVersion, CancellationToken cancellation = default) =>
            Task.FromResult(new SupportSession("session-1", "stream-token", "https://logs.example/batches", DateTimeOffset.Now.AddHours(1)));

        public Task<SupportSession> RefreshSupportSessionAsync(string sessionId, CancellationToken cancellation = default) => CreateSupportSessionAsync(sessionId, "backup", false, "0", cancellation);

        public Task<int> SendSupportBatchAsync(Uri url, string token, byte[] gzippedLines, int sequence, int droppedLines, bool final, CancellationToken cancellation = default)
        {
            using var input = new System.IO.Compression.GZipStream(new MemoryStream(gzippedLines), System.IO.Compression.CompressionMode.Decompress);
            using var reader = new StreamReader(input);
            SupportBatches.Add(reader.ReadToEnd());
            return Task.FromResult(200);
        }

        public List<StructuredLog> Logs { get; } = [];

        public bool FailsLogs { get; set; }

        public Task SubmitStructuredLogAsync(StructuredLog log, CancellationToken cancellation = default)
        {
            if (FailsLogs) return Task.FromException(new HttpRequestException("offline"));
            Logs.Add(log);
            return Task.CompletedTask;
        }
    }

    private sealed class Platform : IPlatform
    {
        public OwnerCheck Owner { get; set; } = OwnerCheck.Confirmed;

        public string ComputerName => "test-pc";

        public string Home => @"C:\Users\test";

        public string AppVersion => "0.0.0";

        public bool AllowsServerSelection { get; set; } = true;

        public bool LaunchAtLogin { get; set; }

        public void Post(Action action) => action();

        public Task OpenAsync(Uri url) => Task.CompletedTask;

        public List<FailureNotice> Notices { get; } = [];

        public void ShowFailureNotification(FailureNotice notice) => Notices.Add(notice);

        public void WithdrawFailureNotifications()
        {
        }

        public Task<OwnerCheck> ConfirmOwnerAsync(string reason) => Task.FromResult(Owner);

        public MachineState MachineNow { get; set; } = new(true, true, true, []);

        public int AwakeHolds { get; private set; }

        public MachineState Machine() => MachineNow;

        public IDisposable KeepAwake()
        {
            AwakeHolds++;
            return new Hold(this);
        }

        public event Action? MachineChanged;

        public void ChangeMachine(MachineState machine)
        {
            MachineNow = machine;
            MachineChanged?.Invoke();
        }

        private sealed class Hold(Platform owner) : IDisposable
        {
            public void Dispose() => owner.AwakeHolds--;
        }
    }

    private sealed class World
    {
        private readonly string directory = Directory.CreateTempSubdirectory("futo-app-").FullName;

        public Engine Engine { get; } = new();

        public Account Account { get; }

        public Platform Platform { get; } = new();

        public World(Func<ISecretStore, ISecretStore>? wrapSecrets = null, Uri? server = null, bool withRepository = true)
        {
            ISecretStore secrets = new InMemorySecretStore(new() { [SecretKey.AccessToken] = "token", [SecretKey.MasterKey] = EngineFixture.MasterKey });
            Account = new Account(wrapSecrets?.Invoke(secrets) ?? secrets);
            new ConfigStore(ConfigFile).Save(AppConfig.Defaults("test-pc", @"C:\Users\test") with
            {
                ServerUrl = server ?? AppConfig.ProductionServerUrl,
                RepositoryId = withRepository ? RepositoryId : null,
                Folders = [@"C:\Users\test\Documents"],
                RecoveryKeyConfirmedAt = DateTimeOffset.Parse("2026-11-01T00:00:00Z", CultureInfo.InvariantCulture),
                TelemetryConsentedAt = DateTimeOffset.Parse("2026-11-01T00:00:00Z", CultureInfo.InvariantCulture),
                OnboardingCompletedAt = DateTimeOffset.Parse("2026-11-01T00:00:00Z", CultureInfo.InvariantCulture),
            });
        }

        public string ConfigFile => Path.Combine(directory, "config.json");

        public AppModel Model(string? missingHelper = null) => new(missingHelper is null ? Engine : null, Account, new ConfigStore(ConfigFile), new LocalFiles(ConfigFile, Path.Combine(directory, "Cache")), Platform, missingHelper);

        public async Task<AppModel> SignedInAsync()
        {
            var model = Model();
            await model.StartAsync();
            Assert.True(model.SignedIn);
            return model;
        }
    }

    private static readonly Snapshot Snapshot = new("snap-1", "snap-1", DateTimeOffset.Parse("2026-11-20T12:00:00Z", CultureInfo.InvariantCulture), [@"C:\Users\test\Documents"], "test-pc", [], null, null, null);

    [Fact]
    public async Task ABackupThatFailsAtOnceLeavesTheAppReadyForTheNextOne()
    {
        var world = new World();
        world.Engine.Backup = _ => Task.FromException<RunRecord>(new UnauthorizedAccessException("denied"));
        var model = await world.SignedInAsync();

        model.BackUpNow();

        Assert.Null(model.Activity);
        Assert.True(model.CanBackUpNow);
        Assert.Equal(BackupStatus.Failed, model.Config.LastRun?.Status);
    }

    [Fact]
    public async Task ARestoreThatFailsAtOnceLeavesTheAppReadyForTheNextOne()
    {
        var world = new World();
        world.Engine.Restore = () => Task.FromException<IReadOnlyList<string>>(new UnauthorizedAccessException("denied"));
        var model = await world.SignedInAsync();

        model.RestoreSnapshot(Snapshot, @"C:\Users\test\Restored");

        Assert.Null(model.Activity);
        Assert.True(model.CanRestore);
        Assert.True(model.CanBackUpNow);
    }

    [Fact]
    public async Task SigningOutDuringABackupDoesNotReportAnInterruptedBackupOnTheNextLaunch()
    {
        var world = new World();
        world.Engine.Backup = async cancellation =>
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            return new RunRecord();
        };
        var model = await world.SignedInAsync();
        model.BackUpNow();

        model.Logout();

        Assert.Null(new ConfigStore(world.ConfigFile).Load("test-pc", @"C:\Users\test").ActiveRunStartedAt);
        Assert.NotEqual(BackupStatus.Incomplete, world.Model().Config.LastRun?.Status);
    }

    [Fact]
    public async Task AStorageReplyFromBeforeSignOutDoesNotOfferToReplaceTheBackup()
    {
        var world = new World();
        var reply = new TaskCompletionSource<IReadOnlyList<RemoteRepository>>();
        world.Account.Repositories = () => reply.Task;
        var model = await world.SignedInAsync();

        model.Logout();
        reply.SetResult([]);
        await Task.Yield();

        Assert.False(model.MissingOnService);
    }

    [Fact]
    public async Task ABackupMissingFromTheServiceIsOfferedForReplacement()
    {
        var world = new World();
        world.Account.Repositories = () => Task.FromResult<IReadOnlyList<RemoteRepository>>([]);
        var model = await world.SignedInAsync();

        await model.RefreshStorageAsync();

        Assert.True(model.MissingOnService);
    }

    [Fact]
    public async Task SigningOutWhenWindowsRefusesToForgetTheSignInStillSignsOutAndSaysWhatToDo()
    {
        var world = new World(secrets => new RefusingDeleteStore(secrets));
        var model = await world.SignedInAsync();

        model.Logout();

        Assert.False(model.SignedIn);
        Assert.Contains("sign out again", model.LastError);
    }

    [Fact]
    public async Task DecliningTheOwnerCheckLeavesTheKeyUnchanged()
    {
        var world = new World();
        world.Platform.Owner = OwnerCheck.Declined;
        var model = await world.SignedInAsync();

        var change = await model.ChangeRecoveryKeyAsync(RepositoryKeys.GenerateMasterKey());

        Assert.IsType<KeyChange.Declined>(change);
        Assert.Equal(0, world.Engine.KeyChanges);
    }

    [Fact]
    public async Task WithoutAWayToConfirmTheOwnerTheKeyStaysHidden()
    {
        var world = new World();
        world.Platform.Owner = OwnerCheck.Unavailable;
        var model = await world.SignedInAsync();

        var key = await model.RevealRecoveryKeyAsync();
        var change = await model.ChangeRecoveryKeyAsync(RepositoryKeys.GenerateMasterKey());

        Assert.Null(key);
        Assert.Contains("cannot confirm your identity", model.LastError);
        Assert.Contains("cannot confirm your identity", Assert.IsType<KeyChange.Failed>(change).Message);
        Assert.Equal(0, world.Engine.KeyChanges);
    }

    [Fact]
    public async Task AKeyChangeThatCouldNotRemoveTheOldKeySaysSo()
    {
        var world = new World();
        world.Engine.ChangeKey = () => Task.FromResult(KeyRotationOutcome.OldKeyRemovalPending);
        var model = await world.SignedInAsync();

        var change = await model.ChangeRecoveryKeyAsync(RepositoryKeys.GenerateMasterKey());

        Assert.Equal(KeyRotationOutcome.OldKeyRemovalPending, Assert.IsType<KeyChange.Changed>(change).Outcome);
    }

    [Fact]
    public async Task PinningAReleaseBuildToProductionForgetsTheTestServerSignIn()
    {
        var world = new World(server: new Uri("http://localhost:3020/"));
        world.Platform.AllowsServerSelection = false;
        var model = world.Model();

        await model.StartAsync();

        Assert.Equal(AppConfig.ProductionServerUrl, model.Config.ServerUrl);
        Assert.False(model.HasSession);
        Assert.Null(world.Account.Secrets.Get(SecretKey.AccessToken));
    }

    [Fact]
    public void BackgroundUpdateChecksWaitForOnboardingAndTheUsersAgreement()
    {
        var model = new World().Model();
        model.UpdateConfig(config => config with { Folders = [], OnboardingCompletedAt = null });

        model.SetAutomaticUpdateChecks(true);
        Assert.False(model.AllowsBackgroundUpdateChecks);

        model.FinishOnboarding([@"C:\Users\test\Documents"], RetentionPreset.Days30, backUpNow: false);
        Assert.True(model.AllowsBackgroundUpdateChecks);

        model.SetAutomaticUpdateChecks(false);
        Assert.False(model.AllowsBackgroundUpdateChecks);
    }

    [Fact]
    public async Task ACompletedBackupWithANoteShowsTheNote()
    {
        var world = new World();
        world.Engine.Backup = _ => Task.FromResult(new RunRecord { Status = BackupStatus.Complete, Message = "Could not delete old snapshots: the backup is locked" });
        var model = await world.SignedInAsync();

        model.BackUpNow();
        await Task.Yield();

        Assert.Equal("Could not delete old snapshots: the backup is locked", model.Completion?.Message);
    }

    [Fact]
    public async Task ACompletedBackupShowsItemsBackedUpNewItemsAndAmountProcessed()
    {
        var world = new World();
        world.Engine.Backup = _ => Task.FromResult(new RunRecord { Status = BackupStatus.Complete, FilesProcessed = 12, BytesProcessed = 5000, FilesNew = 3, DataAdded = 1200 });
        var model = await world.SignedInAsync();

        model.BackUpNow();
        await Task.Yield();

        var message = model.Completion?.Message ?? string.Empty;
        Assert.Contains("12 items", message);
        Assert.Contains("3 new files", message);
        Assert.Contains("added", message);
    }

    [Fact]
    public async Task TryingAgainAfterAFailedSetupKeepsTheSignIn()
    {
        var world = new World(withRepository: false);
        var model = world.Model();
        await model.StartAsync();
        await Task.Yield();
        Assert.IsType<LoginState.Failed>(model.Login);

        await model.StartLoginAsync();
        await Task.Yield();

        Assert.Equal(2, world.Engine.SetUps);
        Assert.True(model.HasSession);
    }

    [Fact]
    public async Task ChoosingABackupTwiceWhileTheKeyIsCheckedDoesNotReportBusy()
    {
        var world = new World(withRepository: false);
        var repository = new RemoteRepository("repo-2", "test-pc", false, "connection-1");
        world.Engine.SetUp = () => Task.FromResult<RepositorySetup>(new RepositorySetup.ChooseExisting([repository], EngineFixture.MasterKey));
        var model = world.Model();
        await model.StartAsync();
        await world.Engine.KeyCheckStarted.Task;

        var first = model.ChooseRepositoryAsync(repository, [repository]);
        var second = model.ChooseRepositoryAsync(repository, [repository]);
        world.Engine.KeyCheckReleased.SetResult();

        Assert.Null(await first);
        Assert.Null(await second);
    }

    [Fact]
    public async Task RemovingTheLastFolderIsRefusedWithAMessage()
    {
        var model = await new World().SignedInAsync();

        model.RemoveFolder(@"C:\Users\test\Documents");

        Assert.Equal([@"C:\Users\test\Documents"], model.Config.Folders);
        Assert.Equal("Add another folder to back up before you remove this one.", model.LastError);
    }

    [Fact]
    public async Task ARestoreRefusedDuringABackupSaysABackupIsRunning()
    {
        var world = new World();
        world.Engine.Backup = async cancellation =>
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            return new RunRecord();
        };
        var model = await world.SignedInAsync();
        model.BackUpNow();

        model.RestoreSnapshot(Snapshot, @"C:\Users\test\Restored");

        Assert.Equal("A backup is running. Wait for it to finish, then try again.", model.LastError);
        model.Cancel();
    }

    [Fact]
    public async Task AScheduledBackupWaitsForItsConditionsAndRunsWhenTheyAreMet()
    {
        var world = new World();
        world.Platform.MachineNow = new MachineState(false, true, true, []);
        var started = 0;
        world.Engine.Backup = _ =>
        {
            started++;
            return Task.FromResult(new RunRecord { Status = BackupStatus.Complete });
        };
        var model = await world.SignedInAsync();
        model.UpdateConfig(config => config with { Conditions = new BackupConditions { Power = true }, ScheduleAnchor = DateTimeOffset.Now.AddDays(-2), LastRun = null });

        model.Tick();

        Assert.Equal(0, started);
        Assert.Equal("Waiting for power", model.NextBackupText);
        Assert.NotNull(model.Config.WaitingForConditionsSince);

        world.Platform.ChangeMachine(new MachineState(true, true, true, []));

        Assert.Equal(1, started);
        Assert.Null(model.Config.WaitingForConditionsSince);
        Assert.Empty(model.WaitingFor);
    }

    [Fact]
    public async Task BackUpNowDoesNotWaitForConditions()
    {
        var world = new World();
        world.Platform.MachineNow = new MachineState(false, false, false, []);
        var started = 0;
        world.Engine.Backup = _ =>
        {
            started++;
            return Task.FromResult(new RunRecord { Status = BackupStatus.Complete });
        };
        var model = await world.SignedInAsync();
        model.UpdateConfig(config => config with { Conditions = new BackupConditions { Power = true, Ethernet = true } });

        model.BackUpNow();

        Assert.Equal(1, started);
    }

    [Theory]
    [InlineData(null, 1)]
    [InlineData(false, 0)]
    public async Task ABackupKeepsThePcAwakeUnlessTurnedOff(bool? keepAwake, int heldDuringBackup)
    {
        var world = new World();
        var finish = new TaskCompletionSource<RunRecord>();
        world.Engine.Backup = _ => finish.Task;
        var model = await world.SignedInAsync();
        model.UpdateConfig(config => config with { KeepAwake = keepAwake });

        model.BackUpNow();
        var held = world.Platform.AwakeHolds;
        finish.SetResult(new RunRecord { Status = BackupStatus.Complete });
        await Task.Yield();

        Assert.Null(model.Activity);

        Assert.Equal(heldDuringBackup, held);
        Assert.Equal(0, world.Platform.AwakeHolds);
    }

    [Fact]
    public async Task AScheduledBackupBlockedByAMissingKeyNotifiesOnceWithItsCause()
    {
        var world = new World();
        world.Engine.StoredKey = null;
        var model = await world.SignedInAsync();
        model.UpdateConfig(config => config with { ScheduleAnchor = DateTimeOffset.Now.AddDays(-2), LastRun = null });
        Assert.True(model.IsMissingRecoveryKey);

        model.Tick();
        model.Tick();

        var notice = Assert.Single(world.Platform.Notices);
        Assert.Equal(FailureNotice.For(BackupFailureReason.MissingRecoveryKey, "futo.cloud", null, DateTimeOffset.Now).Body, notice.Body);
    }

    [Fact]
    public async Task ResticRejectingTheTokenSignsOutWhenTheServerRejectsTheSessionToo()
    {
        var world = new World();
        world.Engine.Backup = _ => Task.FromResult(new RunRecord { Status = BackupStatus.Failed, Message = "Fatal: unexpected HTTP response (401): 401 Unauthorized" });
        var model = await world.SignedInAsync();
        world.Account.Me = () => Task.FromException<AuthInfo>(new YuccaApiException("Unauthorized", 401, null, new Dictionary<string, IEnumerable<string>>(), null));

        model.BackUpNow();
        await Task.Yield();

        Assert.True(model.SessionExpired);
        Assert.Equal(StatusAction.SignIn, model.Status.Action);
    }

    [Fact]
    public async Task ResticRejectingTheTokenKeepsTheSessionWhenTheServerStillAcceptsIt()
    {
        var world = new World();
        world.Engine.Backup = _ => Task.FromResult(new RunRecord { Status = BackupStatus.Failed, Message = "Fatal: unexpected HTTP response (401): 401 Unauthorized" });
        var model = await world.SignedInAsync();

        model.BackUpNow();
        await Task.Yield();

        Assert.False(model.SessionExpired);
    }

    [Fact]
    public async Task SigningInWhenThisPcsBackupIsGoneShowsItAsMissingInsteadOfForgettingIt()
    {
        var world = new World();
        world.Account.Secrets.Delete(SecretKey.AccessToken);
        world.Account.Repositories = () => Task.FromResult<IReadOnlyList<RemoteRepository>>([]);
        var model = world.Model();
        await model.StartAsync();

        await model.StartLoginAsync();
        await Task.Yield();

        Assert.True(model.MissingOnService);
        Assert.Equal(RepositoryId, model.Config.RepositoryId);
        Assert.Equal("This PC's backup is missing", model.Status.Title);
    }

    [Fact]
    public async Task ChangingTheScheduleWaitsForItsNextSlotInsteadOfBackingUpAtOnce()
    {
        var world = new World();
        var started = 0;
        world.Engine.Backup = _ =>
        {
            started++;
            return Task.FromResult(new RunRecord { Status = BackupStatus.Complete });
        };
        var model = await world.SignedInAsync();
        var lastStart = DateTimeOffset.Now.AddHours(-2);
        model.UpdateConfig(config => config with { Schedule = Schedule.Manual, LastRun = new RunRecord { StartedAt = lastStart, FinishedAt = lastStart.AddMinutes(5), Status = BackupStatus.Complete } });

        model.SetSchedule(Schedule.Hourly);
        model.Tick();

        Assert.Equal(0, started);
        Assert.True(model.NextRun > DateTimeOffset.Now);
    }

    [Theory]
    [InlineData(BackupStatus.Failed, "Last backup failed", StatusTint.Critical)]
    [InlineData(BackupStatus.Cancelled, "Backup cancelled", StatusTint.Neutral)]
    [InlineData(BackupStatus.Complete, "Backup complete", StatusTint.Success)]
    public async Task EveryBackupResultHasItsOwnMessage(BackupStatus status, string title, StatusTint tint)
    {
        var world = new World();
        world.Engine.Backup = _ => Task.FromResult(new RunRecord { Status = status, Message = status == BackupStatus.Failed ? "Disk full" : null });
        var model = await world.SignedInAsync();

        model.BackUpNow();
        await Task.Yield();

        Assert.Equal(title, model.Completion?.Title);
        Assert.Equal(tint, model.Completion?.Tint);
    }

    [Fact]
    public void ABackupInterruptedByClosingTheAppIsReportedAtTheNextStart()
    {
        var world = new World();
        var config = new ConfigStore(world.ConfigFile).Load("test-pc", @"C:\Users\test");
        new ConfigStore(world.ConfigFile).Save(config with { ActiveRunStartedAt = DateTimeOffset.Now.AddHours(-1) });

        var model = world.Model();

        Assert.Equal("Backup interrupted", model.Completion?.Title);
    }

    [Fact]
    public async Task AStartupFailureIsSentToFutoOnlyWhenTheUserAsks()
    {
        var world = new World();
        var model = world.Model("restic.exe is missing from FUTO Backups.");
        await model.StartAsync();
        var automatic = world.Account.Logs.Count;

        await model.SendStartupReportAsync();

        Assert.Equal(StartupReportState.Sent, model.StartupReport);
        var sent = Assert.Single(world.Account.Logs.Skip(automatic));
        Assert.Equal("Bootstrap error", sent.Summary);
        Assert.Equal(true, sent.Data["sentByUser"]);
    }

    [Fact]
    public async Task AStartupReportThatCannotBeSentSaysSo()
    {
        var world = new World();
        world.Account.FailsLogs = true;
        var model = world.Model("restic.exe is missing from FUTO Backups.");
        await model.StartAsync();

        await model.SendStartupReportAsync();

        Assert.Equal(StartupReportState.Failed, model.StartupReport);
    }

    [Fact]
    public async Task AStartupReportNeedsASignedInAccount()
    {
        var world = new World();
        world.Account.Secrets.Delete(SecretKey.AccessToken);
        var model = world.Model("restic.exe is missing from FUTO Backups.");
        await model.StartAsync();

        await model.SendStartupReportAsync();

        Assert.Equal(StartupReportState.NeedsSignIn, model.StartupReport);
    }

    [Fact]
    public async Task AWrongKeyIsCheckedAgainstEveryListedBackup()
    {
        var typed = RepositoryKeys.GenerateMasterKey();
        var desktop = new RemoteRepository("repo-a", "test-pc", false, "connection-1");
        var laptop = new RemoteRepository("repo-b", "laptop", false, "connection-1");
        var world = new World(withRepository: false);
        world.Engine.SetUp = () => Task.FromResult<RepositorySetup>(new RepositorySetup.ChooseExisting([desktop, laptop], EngineFixture.MasterKey));
        world.Engine.KeyOpens = (id, key) => key == typed && id == laptop.Id;
        var model = world.Model();
        await model.StartAsync();
        model.ShowRecoveryKeyStep(new RecoveryKeyStep.RepositoryKey(desktop, [desktop, laptop], false));

        var error = await model.EnterRepositoryKeyAsync(typed, desktop);
        await world.Engine.KeyChecksDone.Task;

        Assert.Equal("That key does not open test-pc.", error);
        Assert.Equal(StoredKeyCheck.DoesNotOpen, model.EnteredKeyChecks[desktop.Id]);
        Assert.Equal(StoredKeyCheck.Opens, model.EnteredKeyChecks[laptop.Id]);
        Assert.Null(model.Config.RepositoryId);
    }

    [Fact]
    public async Task ReconnectingToABackupBringsBackTheFoldersItBackedUp()
    {
        var kept = Directory.CreateTempSubdirectory("futo-kept-").FullName;
        var gone = Path.Combine(Path.GetTempPath(), "futo-gone-" + Guid.NewGuid());
        var repository = new RemoteRepository("repo-2", "test-pc", false, "connection-1");
        var world = new World(withRepository: false);
        world.Engine.SetUp = () => Task.FromResult<RepositorySetup>(new RepositorySetup.ChooseExisting([repository], EngineFixture.MasterKey));
        world.Engine.KeyOpens = (_, _) => true;
        world.Engine.SnapshotList = [new Snapshot("s1", "s1", DateTimeOffset.Now, [kept, gone], "test-pc", [], null, null, null)];
        var model = world.Model();
        await model.StartAsync();
        model.UpdateConfig(config => config with { Folders = [], OnboardingCompletedAt = null });

        Assert.Null(await model.ChooseRepositoryAsync(repository, [repository]));

        Assert.Equal(repository.Id, model.Config.RepositoryId);
        Assert.Equal<string>([kept], model.Config.Folders);
        Assert.False(model.NeedsOnboarding);
    }

    [Fact]
    public async Task WithoutAServerMeasurementTheStorageIsAnEstimateMadeOnThisPc()
    {
        var world = new World();
        world.Engine.LocalSize = 5_000_000_000;
        var model = await world.SignedInAsync();

        await model.RefreshStorageAsync();

        Assert.Equal(5_000_000_000, model.RepositorySize);
        Assert.True(model.RepositorySizeEstimated);
    }

    [Fact]
    public async Task TheServerMeasurementIsShownWhenThereIsOne()
    {
        var world = new World();
        world.Engine.LocalSize = 5_000_000_000;
        world.Account.Repositories = () => Task.FromResult<IReadOnlyList<RemoteRepository>>([new RemoteRepository(RepositoryId, "test-pc", false, "connection-1", SizeBytes: 7_000_000_000)]);
        var model = await world.SignedInAsync();

        await model.RefreshStorageAsync();

        Assert.Equal(7_000_000_000, model.RepositorySize);
        Assert.False(model.RepositorySizeEstimated);
    }

    [Fact]
    public async Task AnEmptyBackupNameIsRejected()
    {
        var world = new World();
        var model = await world.SignedInAsync();

        Assert.Equal("Enter a backup name.", await model.RenameRepositoryAsync("   "));
        Assert.Empty(world.Account.Updates);
    }

    [Fact]
    public async Task RenamingSendsTheTrimmedNameToTheService()
    {
        var world = new World();
        var model = await world.SignedInAsync();

        Assert.Null(await model.RenameRepositoryAsync("  Study PC "));

        Assert.Equal(("Study PC", (bool?)null), Assert.Single(world.Account.Updates));
        Assert.Equal("Study PC", model.ThisRepository?.Name);
    }

    [Fact]
    public async Task WriteOnceIsTurnedOnDirectlyButTurningItOffGoesThroughTheBrowser()
    {
        var world = new World();
        var model = await world.SignedInAsync();

        Assert.Null(await model.EnableWriteOnceAsync());
        Assert.True(model.Config.IsWriteOnce);
        Assert.Equal((null, (bool?)true), Assert.Single(world.Account.Updates));

        Assert.Null(await model.DisableWriteOnceAsync());
        Assert.Equal(("repository.disable-worm", RepositoryId), Assert.Single(world.Account.Tickets));
        Assert.True(model.Config.IsWriteOnce);
    }

    private static Task FinishedAsync(AppModel model)
    {
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        model.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AppModel.Completion) && model.Completion is not null)
            {
                finished.TrySetResult();
            }
        };
        return finished.Task;
    }

    [Fact]
    public async Task SupportModeRecordsTheRunLocallyWithFileNamesHiddenAndUsesUpOneRun()
    {
        var world = new World();
        var model = await world.SignedInAsync();
        model.SetSupportMode(2, false, false);

        var finished = FinishedAsync(model);
        model.BackUpNow();
        await finished;

        var entry = model.Config.Runs![0];
        Assert.NotNull(entry.SupportLog);
        Assert.Null(entry.SupportCode);
        var log = await File.ReadAllTextAsync(entry.SupportLog, TestContext.Current.CancellationToken);
        Assert.Contains("<path:", log);
        Assert.DoesNotContain("taxes", log);
        Assert.Equal(1, model.Config.SupportModeRunsRemaining);
    }

    [Fact]
    public async Task SupportModeSendsTheRunToFutoAndGivesASupportCodeWhenTheUserAgrees()
    {
        var world = new World();
        world.Account.Me = () => Task.FromResult(new AuthInfo("user-1", "Sam", "sam@example.com", "connection-1", new Dictionary<string, bool> { [AuthInfo.SupportLogStreaming] = true }));
        var model = await world.SignedInAsync();
        model.SetSupportMode(1, true, true);

        var finished = FinishedAsync(model);
        model.BackUpNow();
        await finished;

        Assert.Equal("session-1", model.Config.Runs![0].SupportCode);
        Assert.Contains("taxes.pdf", string.Concat(world.Account.SupportBatches));
        Assert.Null(model.Config.SupportModeRunsRemaining);
    }

    [Fact]
    public async Task SupportModeRecordsARestoreWithoutUsingUpABackupRun()
    {
        var world = new World();
        var model = await world.SignedInAsync();
        model.SetSupportMode(1, false, false);
        var recorded = new TaskCompletionSource();
        model.PropertyChanged += (_, _) =>
        {
            if (model.Config.Runs is [{ Kind: RunKind.Restore }, ..])
            {
                recorded.TrySetResult();
            }
        };

        model.RestoreSnapshot(Snapshot, @"C:\Users\test\Restored");
        await recorded.Task;

        var entry = model.Config.Runs![0];
        Assert.NotNull(entry.SupportLog);
        Assert.Null(entry.SupportCode);
        var log = await File.ReadAllTextAsync(entry.SupportLog, TestContext.Current.CancellationToken);
        Assert.Contains("<path:", log);
        Assert.DoesNotContain("taxes", log);
        Assert.Equal(1, model.Config.SupportModeRunsRemaining);
    }
}
