using System.Globalization;

using FutoBackups.Core;
using FutoBackups.Core.Api;
using FutoBackups.Core.Engine;
using FutoBackups.Core.Models;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Support;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Mock;

public static class MockServices
{
    public static AppModel Model(IPlatform platform)
    {
        var directory = Path.Combine(Path.GetTempPath(), "FUTO Backups Mock");
        Directory.CreateDirectory(directory);
        var secrets = new MockSecretStore(Path.Combine(directory, "secrets.json"));
        var account = new MockAccount(secrets);
        var config = Path.Combine(directory, "config.json");
        var files = new LocalFiles(config, Path.Combine(directory, "Cache"));
        return new AppModel(new MockEngine(secrets, platform.Home, account.RepositoryCreated), account, new ConfigStore(config), files, new MockPlatform(platform), null);
    }
}

internal sealed class MockPlatform(IPlatform platform) : IPlatform
{
    public string ComputerName => platform.ComputerName;

    public string Home => platform.Home;

    public string AppVersion => platform.AppVersion;

    public bool AllowsServerSelection => true;

    public bool LaunchAtLogin { get; set; }

    public void Post(Action action) => platform.Post(action);

    public Task OpenAsync(Uri url) => Task.CompletedTask;

    public void ShowFailureNotification(FailureNotice notice) => platform.ShowFailureNotification(notice);

    public void WithdrawFailureNotifications() => platform.WithdrawFailureNotifications();

    public Task<OwnerCheck> ConfirmOwnerAsync(string message) => Task.FromResult(OwnerCheck.Confirmed);

    public MachineState Machine() => platform.Machine();

    public IDisposable KeepAwake() => platform.KeepAwake();

    public event Action? MachineChanged
    {
        add => platform.MachineChanged += value;
        remove => platform.MachineChanged -= value;
    }
}

internal sealed class MockAccount(ISecretStore secrets) : IAccountService, IAccountApi
{
    public ISecretStore Secrets { get; } = secrets;

    public Task<ServerInfo> ResolveAsync(Uri server, CancellationToken cancellation = default) => Task.FromResult(new ServerInfo(server));

    public Task<DeviceAuthorization> StartDeviceAuthorizationAsync(Uri server, CancellationToken cancellation = default) =>
        Task.FromResult(new DeviceAuthorization("mock-device", "BXKR-TQLM", "https://futo.cloud/device", "https://futo.cloud/device?code=BXKR-TQLM", 900, 5));

    public async Task<string> WaitForTokenAsync(Uri server, DeviceAuthorization authorization, string connectionName, CancellationToken cancellation = default)
    {
        await Task.Delay(TimeSpan.FromSeconds(12), cancellation);
        return "mock-token";
    }

    public Task<IAccountApi> ClientAsync(Uri server, string? token, CancellationToken cancellation = default) => Task.FromResult<IAccountApi>(this);

    public Task OpenBrowserAsync(Uri url) => Task.CompletedTask;

    public Task<AuthInfo> MeAsync(CancellationToken cancellation = default) => Task.FromResult(new AuthInfo("mock-user", "Sam", "sam@example.com", "mock-connection", new Dictionary<string, bool> { [AuthInfo.SupportLogStreaming] = true }));

    public Task LogoutAsync(CancellationToken cancellation = default) => Task.CompletedTask;

    private (string Id, DateTimeOffset At)? deletion;
    private string name = Environment.MachineName;
    private bool worm;
    private DateTimeOffset? wormOffAt;

    public void RepositoryCreated() => deletion = null;

    public Task<IReadOnlyList<RemoteRepository>> ListRepositoriesAsync(CancellationToken cancellation = default) =>
        Task.FromResult<IReadOnlyList<RemoteRepository>>(new RemoteRepository[]
        {
            new RemoteRepository(MockEngine.RepositoryId, name, worm && (wormOffAt is not { } off || DateTimeOffset.Now < off), "mock-connection", "windows", 48_213_000_000),
            new RemoteRepository("mock-laptop", "sam-laptop", false, "mock-laptop-connection", "windows", 112_000_000_000),
        }.Where(repository => deletion is not { } pending || DateTimeOffset.Now < pending.At || repository.Id != pending.Id).ToList());

    public Task<RemoteRepository> UpdateRepositoryAsync(string repositoryId, string? name = null, bool? worm = null, CancellationToken cancellation = default)
    {
        this.name = name ?? this.name;
        if (worm is { } writeOnce)
        {
            this.worm = writeOnce;
            wormOffAt = null;
        }

        return Task.FromResult(new RemoteRepository(repositoryId, this.name, this.worm, "mock-connection", "windows"));
    }

    public Task<Uri> CreateTicketAsync(string action, string repositoryId, CancellationToken cancellation = default)
    {
        if (action == TicketActions.DisableWriteOnce)
        {
            wormOffAt = DateTimeOffset.Now.AddSeconds(20);
            return Task.FromResult(new Uri("https://futo.cloud/disable-write-once"));
        }

        deletion = (repositoryId, DateTimeOffset.Now.AddSeconds(20));
        return Task.FromResult(new Uri("https://futo.cloud/delete"));
    }

    public Task DeleteConnectionAsync(string id, CancellationToken cancellation = default) => Task.CompletedTask;

    public Task<SupportSession> CreateSupportSessionAsync(string jobId, string jobName, bool includesPaths, string clientVersion, CancellationToken cancellation = default) =>
        Task.FromResult(new SupportSession("7f3c2a9e-mock", "mock-token", "https://logs.futo.cloud/batches", DateTimeOffset.Now.AddHours(1)));

    public Task<SupportSession> RefreshSupportSessionAsync(string sessionId, CancellationToken cancellation = default) => CreateSupportSessionAsync(sessionId, "backup", false, "mock", cancellation);

    public Task<int> SendSupportBatchAsync(Uri url, string token, byte[] gzippedLines, int sequence, int droppedLines, bool final, CancellationToken cancellation = default) => Task.FromResult(200);

    public Task SubmitStructuredLogAsync(StructuredLog log, CancellationToken cancellation = default) => Task.CompletedTask;
}

internal sealed class MockEngine(ISecretStore secrets, string home, Action repositoryCreated) : IBackupEngine
{
    public const string RepositoryId = "0b6a1f6e-3c1d-4c2a-9f7e-5d4b3a2c1e0f";

    private const long TotalBytes = 48_213_000_000;
    private readonly List<Snapshot> snapshots = Enumerable.Range(1, 8)
        .Select(index => Snapshot(home, DateTimeOffset.Now.AddHours(-index * 19), index == 8 ? null : 40_000_000L * index))
        .ToList();

    private int backups;
    private int restores;
    private int keyChanges;
    private readonly string attemptsFile = Path.Combine(Path.GetTempPath(), "FUTO Backups Mock", "attempts.txt");

    public bool IsRunning { get; private set; }

    public string MasterKey()
    {
        if (secrets.Get(SecretKey.MasterKey) is { } stored) return stored;
        var key = RepositoryKeys.GenerateMasterKey();
        secrets.Set(SecretKey.MasterKey, key);
        return key;
    }

    public string? StoredMasterKey() => secrets.Get(SecretKey.MasterKey);

    public void ImportMasterKey(string input) =>
        secrets.Set(SecretKey.MasterKey, RepositoryKeys.NormalizedMasterKey(input) ?? throw new InvalidMasterKeyException());

    public Task<RepositorySetup> SetUpRepositoryAsync(AppConfig config, bool offeringExisting, CancellationToken cancellation = default)
    {
        repositoryCreated();
        return Task.FromResult<RepositorySetup>(new RepositorySetup.Ready(RepositoryId));
    }

    public async Task<RunRecord> BackupAsync(AppConfig config, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default)
    {
        var started = DateTimeOffset.Now;
        IsRunning = true;
        try
        {
            onActivity(new EngineActivity.Preparing());
            var attempt = (File.Exists(attemptsFile) ? int.Parse(File.ReadAllText(attemptsFile), CultureInfo.InvariantCulture) : 0) + 1;
            File.WriteAllText(attemptsFile, attempt.ToString(CultureInfo.InvariantCulture));
            if (attempt % 3 == 0) throw new HttpRequestException("connect failed", new System.Net.Sockets.SocketException(10061));
            await Task.Delay(1500, cancellation);
            var meter = new UploadSpeedMeter(config.Throttle);
            var random = new Random(7);
            long uploaded = 0;
            for (var step = 0; step <= 100; step++)
            {
                await Task.Delay(400, cancellation);
                uploaded += 600_000 + random.Next(0, 400_000);
                var speed = meter.Record(uploaded, step * 0.15);
                var fraction = step / 100.0;
                onActivity(new EngineActivity.BackingUp(new BackupProgress(fraction, 182_340, (int)(182_340 * fraction), TotalBytes, (long)(TotalBytes * fraction), (int)((1 - fraction) * 15)), speed));
            }

            onActivity(new EngineActivity.Finishing(FinishingStep.CheckingCloudOnlyFiles));
            await Task.Delay(1000, cancellation);
            onActivity(new EngineActivity.Pruning());
            await Task.Delay(1000, cancellation);
            var snapshot = Snapshot(home, DateTimeOffset.Now, 120_000_000);
            snapshots.Insert(0, snapshot);
            var record = new RunRecord { StartedAt = started, FinishedAt = DateTimeOffset.Now, Status = BackupStatus.Complete, SnapshotId = snapshot.Id, FilesNew = 37, DataAdded = snapshot.DataAdded, FilesProcessed = 182_340, BytesProcessed = TotalBytes };
            if (++backups % 2 == 0) return record;
            var warnings = new BackupWarnings(
                [
                    new BackupWarning(Path.Combine(home, "Documents", "Outlook Files", "sam@example.com.pst"), "The process cannot access the file because it is being used by another process."),
                    new BackupWarning(Path.Combine(home, "Documents", "My Music", "desktop.ini"), "Access is denied."),
                ],
                2);
            var cloudOnly = new CloudOnlySkip(2, 3_420_000_000, [Path.Combine(home, "OneDrive", "Photos", "2019") + "\\", Path.Combine(home, "OneDrive", "Documents", "Lease.pdf")]);
            return record with { Status = BackupStatus.Warn, Message = warnings.Summary, Warnings = warnings, CloudOnlySkipped = cloudOnly };
        }
        catch (OperationCanceledException)
        {
            return new RunRecord { StartedAt = started, FinishedAt = DateTimeOffset.Now, Status = BackupStatus.Cancelled };
        }
        finally
        {
            IsRunning = false;
        }
    }

    public Task<IReadOnlyList<Snapshot>> SnapshotsAsync(AppConfig config, CancellationToken cancellation = default)
    {
        var expire = Path.Combine(Path.GetTempPath(), "FUTO Backups Mock", "expire");
        if (!File.Exists(expire)) return Task.FromResult<IReadOnlyList<Snapshot>>(snapshots.ToList());
        File.Delete(expire);
        throw new YuccaApiException("Unauthorized", 401, null, new Dictionary<string, IEnumerable<string>>(), null);
    }

    public async Task<IReadOnlyList<SnapshotEntry>> ListDirectoryAsync(AppConfig config, string snapshotId, string path, CancellationToken cancellation = default)
    {
        await Task.Delay(300, cancellation);
        var random = new Random(path.GetHashCode(StringComparison.Ordinal));
        if (path.Count(character => character == '/') > 6) return [];
        string[] folders = ["2024", "2025", "Archive", "Drafts", "Exports"];
        string[] files = ["Budget.xlsx", "Notes.md", "Photo 0412.jpg", "Report.pdf", "Scan.png", "Contract.docx"];
        var entries = folders.OrderBy(_ => random.Next()).Take(random.Next(0, 4))
            .Select(name => new SnapshotEntry(name, $"{path}/{name}", ResticNodeKind.Directory, null, DateTimeOffset.Now.AddDays(-random.Next(1, 300))))
            .Concat(files.OrderBy(_ => random.Next()).Take(random.Next(1, 6))
                .Select(name => new SnapshotEntry(name, $"{path}/{name}", ResticNodeKind.File, random.NextInt64(2_000, 40_000_000), DateTimeOffset.Now.AddDays(-random.Next(1, 400)))));
        return SnapshotListing.Sorted(entries);
    }

    public Task<IReadOnlyList<string>> RestoreAsync(AppConfig config, string snapshotId, IReadOnlyList<RestoreItem> items, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default) =>
        SimulateRestoreAsync(items.Select(item => item.Target).ToList(), onActivity, cancellation);

    public Task<IReadOnlyList<string>> RestoreAsync(AppConfig config, string snapshotId, IReadOnlyList<SnapshotEntry> selection, string target, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default) =>
        SimulateRestoreAsync([target], onActivity, cancellation);

    public Task<IReadOnlyList<RemoteRepository>> WindowsRepositoriesAsync(AppConfig config, CancellationToken cancellation = default) =>
        Task.FromResult<IReadOnlyList<RemoteRepository>>([
            new RemoteRepository(RepositoryId, config.Host, false, null, "windows", 48_213_000_000, DateTimeOffset.Now.AddHours(-3)),
            new RemoteRepository("mock-laptop", "sam-laptop", false, null, "windows", 112_000_000_000, DateTimeOffset.Now.AddDays(-2)),
        ]);

    public Task<IReadOnlyList<RemoteRepository>> OtherRepositoriesAsync(AppConfig config, CancellationToken cancellation = default) =>
        Task.FromResult<IReadOnlyList<RemoteRepository>>([]);

    public Task<ExistingBackupUnlock> UnlockExistingRepositoryAsync(string repositoryId, string key, bool isStored, AppConfig config, CancellationToken cancellation = default)
    {
        if (isStored && repositoryId != RepositoryId) return Task.FromResult(ExistingBackupUnlock.WrongKey);
        if (!isStored)
        {
            ImportMasterKey(key);
        }

        return Task.FromResult(ExistingBackupUnlock.Unlocked);
    }

    public Task CheckKeyAsync(string key, IReadOnlyList<string> repositoryIds, AppConfig config, Action<string, StoredKeyCheck> onCheck, CancellationToken cancellation = default)
    {
        foreach (var id in repositoryIds) onCheck(id, id == RepositoryId ? StoredKeyCheck.Opens : StoredKeyCheck.DoesNotOpen);
        return Task.CompletedTask;
    }

    public async Task<KeyRotationOutcome> ChangeMasterKeyAsync(string input, AppConfig config, CancellationToken cancellation = default)
    {
        await Task.Delay(2000, cancellation);
        ImportMasterKey(input);
        return ++keyChanges % 2 == 0 ? KeyRotationOutcome.OldKeyRemovalPending : KeyRotationOutcome.Complete;
    }

    public Task<bool> FinishPendingKeyRotationAsync(AppConfig config, CancellationToken cancellation = default) => Task.FromResult(false);

    public Task<long?> RepositorySizeAsync(AppConfig config, CancellationToken cancellation = default) => Task.FromResult<long?>(TotalBytes);

    public Task UpdateThrottleAsync(Throttle throttle) => Task.CompletedTask;

    private async Task<IReadOnlyList<string>> SimulateRestoreAsync(IReadOnlyList<string> targets, Action<EngineActivity> onActivity, CancellationToken cancellation)
    {
        if (++restores % 2 == 0)
        {
            throw new HttpRequestException("connect failed", new System.Net.Sockets.SocketException(10061));
        }

        for (var step = 0; step <= 20; step++)
        {
            await Task.Delay(500, cancellation);
            onActivity(new EngineActivity.Restoring(new RestoreStep(1, 1, "Documents", new RestoreProgress(step / 20.0, 400, step * 20, 2_000_000_000, step * 100_000_000L))));
        }

        foreach (var target in targets) Directory.CreateDirectory(target);

        return targets;
    }

    private static Snapshot Snapshot(string home, DateTimeOffset time, long? added) => new(
        Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N")[..8], time,
        [Path.Combine(home, "Documents"), Path.Combine(home, "Pictures"), Path.Combine(home, "Desktop")],
        Environment.MachineName, [], 182_340, TotalBytes, added);
}

internal sealed class MockSecretStore(string file) : ISecretStore
{
    private Dictionary<SecretKey, string> Values =>
        File.Exists(file) ? System.Text.Json.JsonSerializer.Deserialize<Dictionary<SecretKey, string>>(File.ReadAllText(file)) ?? [] : [];

    public string? Get(SecretKey key) => Values.GetValueOrDefault(key);

    public void Set(SecretKey key, string value) => Save(new Dictionary<SecretKey, string>(Values) { [key] = value });

    public void Delete(SecretKey key)
    {
        var values = Values;
        values.Remove(key);
        Save(values);
    }

    private void Save(Dictionary<SecretKey, string> values) => File.WriteAllText(file, System.Text.Json.JsonSerializer.Serialize(values));
}
