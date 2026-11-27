using System.Net.NetworkInformation;
using System.Threading.Channels;

using FutoBackups.Core.Api;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Engine;

public sealed record EngineEnvironment(
    ISecretStore Secrets,
    Func<Uri, CancellationToken, Task<ServerInfo>> Discover,
    Func<Uri, string, IYuccaRepositoryApi> MakeApi,
    IResticExecuting Restic,
    IResticProxyLaunching ProxyLauncher,
    string CacheDirectory,
    int ProcessorCount,
    Func<DateTimeOffset> Now)
{
    public string AppVersion { get; init; } = "dev";

    public TimeSpan TelemetryTimeout { get; init; } = TimeSpan.FromSeconds(10);

    public ICloudOnlyScanner CloudOnlyScanner { get; init; } = new NoCloudOnlyScan();

    public Func<Action, IDisposable> WatchNetworkChanges { get; init; } = WatchSystemNetwork;

    public Func<TimeSpan, CancellationToken, Task> Sleep { get; init; } = Task.Delay;

    public TimeSpan UploadTickInterval { get; init; } = TimeSpan.FromSeconds(1);

    public Telemetry Telemetry { get; init; } = new();

    public Func<string, bool> CreateRestoreDirectory { get; init; } = RestorePlan.CreateDirectoryExclusively;

    public Func<string, bool> CreateRestoreStaging { get; init; } = RestorePlan.CreateDirectoryExclusively;

    public Func<string, string, bool> MoveRestoredItem { get; init; } = RestorePlan.MoveExclusively;

    public Action<string> RemoveRestoreStaging { get; init; } = RestorePlan.RemoveStaging;

    private static IDisposable WatchSystemNetwork(Action changed)
    {
        var debounce = new Timer(_ => changed(), null, Timeout.Infinite, Timeout.Infinite);
        NetworkAddressChangedEventHandler handler = (_, _) => debounce.Change(TimeSpan.FromSeconds(1), Timeout.InfiniteTimeSpan);
        NetworkChange.NetworkAddressChanged += handler;
        return new Subscription(() =>
        {
            NetworkChange.NetworkAddressChanged -= handler;
            debounce.Dispose();
        });
    }

    private sealed class Subscription(Action dispose) : IDisposable
    {
        public void Dispose() => dispose();
    }
}

public enum FinishingStep
{
    CheckingCloudOnlyFiles,
}

public abstract record EngineActivity
{
    public sealed record Preparing : EngineActivity;

    public sealed record BackingUp(BackupProgress Progress, UploadSpeed Speed) : EngineActivity;

    public sealed record Finishing(FinishingStep Step) : EngineActivity;

    public sealed record Pruning : EngineActivity;

    public sealed record Restoring(RestoreStep Step) : EngineActivity;

    public sealed record ChangingRecoveryKey : EngineActivity;

    public bool IsCancellable => this is not ChangingRecoveryKey;
}

public abstract record RepositorySetup
{
    public sealed record Ready(string RepositoryId) : RepositorySetup;

    public sealed record ChooseExisting(IReadOnlyList<RemoteRepository> Repositories, string MasterKey) : RepositorySetup;
}

public enum StoredKeyCheck
{
    Checking,
    Opens,
    DoesNotOpen,
    Unknown,
}

public enum ExistingBackupUnlock
{
    Unlocked,
    NeedsKey,
    WrongKey,
}

internal sealed class Outbox
{
    private readonly Channel<Func<CancellationToken, Task>> jobs = Channel.CreateUnbounded<Func<CancellationToken, Task>>();

    public Outbox(TimeSpan timeout)
    {
        _ = Task.Run(async () =>
        {
            await foreach (var job in jobs.Reader.ReadAllAsync())
            {
                using var deadline = new CancellationTokenSource(timeout);
                try
                {
                    await job(deadline.Token);
                }
                catch (Exception)
                {
                }
            }
        });
    }

    public void Enqueue(Func<CancellationToken, Task> job) => jobs.Writer.TryWrite(job);

    public Task FlushAsync()
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        Enqueue(_ =>
        {
            done.TrySetResult();
            return Task.CompletedTask;
        });
        return done.Task;
    }
}
