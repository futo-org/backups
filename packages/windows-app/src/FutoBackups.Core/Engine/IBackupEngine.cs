using FutoBackups.Core.Api;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Support;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Engine;

public interface IBackupEngine
{
    bool IsRunning { get; }

    string MasterKey();

    string? StoredMasterKey();

    void ImportMasterKey(string input);

    Task<RepositorySetup> SetUpRepositoryAsync(AppConfig config, bool offeringExisting, CancellationToken cancellation = default);

    Task<RunRecord> BackupAsync(AppConfig config, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default);

    Task<IReadOnlyList<Snapshot>> SnapshotsAsync(AppConfig config, CancellationToken cancellation = default);

    Task<IReadOnlyList<SnapshotEntry>> ListDirectoryAsync(AppConfig config, string snapshotId, string path, CancellationToken cancellation = default);

    Task<IReadOnlyList<string>> RestoreAsync(AppConfig config, string snapshotId, IReadOnlyList<RestoreItem> items, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default);

    Task<IReadOnlyList<string>> RestoreAsync(AppConfig config, string snapshotId, IReadOnlyList<SnapshotEntry> selection, string target, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default);

    Task<IReadOnlyList<RemoteRepository>> WindowsRepositoriesAsync(AppConfig config, CancellationToken cancellation = default);

    Task<IReadOnlyList<RemoteRepository>> OtherRepositoriesAsync(AppConfig config, CancellationToken cancellation = default);

    Task<ExistingBackupUnlock> UnlockExistingRepositoryAsync(string repositoryId, string key, bool isStored, AppConfig config, CancellationToken cancellation = default);

    Task CheckKeyAsync(string key, IReadOnlyList<string> repositoryIds, AppConfig config, Action<string, StoredKeyCheck> onCheck, CancellationToken cancellation = default);

    Task<KeyRotationOutcome> ChangeMasterKeyAsync(string input, AppConfig config, CancellationToken cancellation = default);

    Task<bool> FinishPendingKeyRotationAsync(AppConfig config, CancellationToken cancellation = default);

    Task<long?> RepositorySizeAsync(AppConfig config, CancellationToken cancellation = default);

    Task UpdateThrottleAsync(Throttle throttle);
}

public interface IAccountService
{
    ISecretStore Secrets { get; }

    Task<ServerInfo> ResolveAsync(Uri server, CancellationToken cancellation = default);

    Task<DeviceAuthorization> StartDeviceAuthorizationAsync(Uri server, CancellationToken cancellation = default);

    Task<string> WaitForTokenAsync(Uri server, DeviceAuthorization authorization, string connectionName, CancellationToken cancellation = default);

    Task<IAccountApi> ClientAsync(Uri server, string? token, CancellationToken cancellation = default);

    Task OpenBrowserAsync(Uri url);
}

public sealed class AccountService(Discovery discovery, HttpClient http, ISecretStore secrets, Func<Uri, Task> openBrowser) : IAccountService
{
    public ISecretStore Secrets { get; } = secrets;

    public Task<ServerInfo> ResolveAsync(Uri server, CancellationToken cancellation = default) => discovery.ResolveAsync(server, cancellation);

    public async Task<DeviceAuthorization> StartDeviceAuthorizationAsync(Uri server, CancellationToken cancellation = default)
    {
        var info = await ResolveAsync(server, cancellation);
        return await new YuccaClient(info.ApiRoot, http).StartDeviceAuthorizationAsync(cancellation);
    }

    public async Task<string> WaitForTokenAsync(Uri server, DeviceAuthorization authorization, string connectionName, CancellationToken cancellation = default)
    {
        var info = await ResolveAsync(server, cancellation);
        return await new YuccaClient(info.ApiRoot, http).WaitForTokenAsync(authorization, connectionName, cancellation);
    }

    public async Task<IAccountApi> ClientAsync(Uri server, string? token, CancellationToken cancellation = default)
    {
        var info = await ResolveAsync(server, cancellation);
        return new YuccaClient(info.ApiRoot, http, token);
    }

    public Task OpenBrowserAsync(Uri url) => openBrowser(url);
}
