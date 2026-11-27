using System.Diagnostics;
using System.Globalization;

using FutoBackups.Core.Api;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Support;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Engine;

public sealed partial class BackupEngine : IBackupEngine
{
    internal sealed record Session(IResticProxyHandle Proxy, ResticContext Context, IDisposable NetworkWatch) : IAsyncDisposable
    {
        public async ValueTask DisposeAsync()
        {
            NetworkWatch.Dispose();
            await Proxy.DisposeAsync();
        }
    }

    private readonly Outbox outbox;
    private readonly Dictionary<Uri, ServerInfo> serverCache = [];
    private readonly Lock gate = new();
    private bool running;
    private ISupportLogSink? support;
    private bool? futoRestic;
    private IResticProxyHandle? liveProxy;

    public BackupEngine(EngineEnvironment environment)
    {
        Environment = environment;
        outbox = new Outbox(environment.TelemetryTimeout);
    }

    public EngineEnvironment Environment { get; }

    public bool IsRunning
    {
        get
        {
            lock (gate)
            {
                return running;
            }
        }
    }

    public Task FlushOutboxAsync() => outbox.FlushAsync();

    public async Task UpdateThrottleAsync(Throttle throttle)
    {
        if (!IsRunning || liveProxy is not { } proxy) return;
        try
        {
            await proxy.SetThrottleAsync(throttle);
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException)
        {
        }
    }

    public string MasterKey()
    {
        if (Environment.Secrets.Get(SecretKey.MasterKey) is { } stored) return stored;
        var generated = RepositoryKeys.GenerateMasterKey();
        Environment.Secrets.Set(SecretKey.MasterKey, generated);
        return generated;
    }

    public string? StoredMasterKey() => Environment.Secrets.Get(SecretKey.MasterKey);

    public void ImportMasterKey(string input) =>
        Environment.Secrets.Set(SecretKey.MasterKey, RepositoryKeys.NormalizedMasterKey(input) ?? throw new InvalidMasterKeyException());

    public async Task<RepositorySetup> SetUpRepositoryAsync(AppConfig config, bool offeringExisting, CancellationToken cancellation = default)
    {
        if (offeringExisting && config.RepositoryId is null)
        {
            var existing = await WindowsRepositoriesAsync(config, cancellation);
            if (existing.Count > 0 && StoredMasterKey() is { } masterKey) return new RepositorySetup.ChooseExisting(existing, masterKey);
            cancellation.ThrowIfCancellationRequested();
        }

        return new RepositorySetup.Ready(await EnsureRepositoryAsync(config, cancellation));
    }

    public async Task<string> EnsureRepositoryAsync(AppConfig config, CancellationToken cancellation = default)
    {
        using var claim = Claim();
        if (config.RepositoryId is { } existing) return existing;
        var token = AccessToken();
        var server = await ServerInfoAsync(config.ServerUrl, cancellation);
        var api = Environment.MakeApi(server.ApiRoot, token);
        var masterKey = RequireMasterKey();
        var created = await api.CreateRepositoryAsync(config.Host, cancellation);
        await using (var session = await StartSessionAsync(config, created.Id, masterKey, token, cancellation))
        {
            var result = await Restic.RunAsync(ResticCommand.Initialize(session.Context), null, cancellation);
            if (result.ExitCode != ResticExitCode.Success)
            {
                throw new EngineException(EngineError.Restic, ResticCommand.FailureMessage(result), result.ExitCode);
            }
        }

        Report(api, config, "Created repository", new() { ["repositoryId"] = created.Id, ["backendId"] = Telemetry.FutoCloudBackendId });
        return created.Id;
    }

    public async Task<RunRecord> BackupAsync(AppConfig config, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default)
    {
        var repositoryId = config.RepositoryId ?? throw new EngineException(EngineError.NoRepository);
        if (config.Folders.Count == 0) throw new EngineException(EngineError.NoFolders);
        var token = AccessToken();
        var masterKey = RequireMasterKey();
        using var claim = Claim(support);
        var startedAt = Environment.Now();
        var stopwatch = Stopwatch.StartNew();
        onActivity(new EngineActivity.Preparing());
        var status = BackupStatus.Failed;
        string? message = null;
        string? failureDetail = null;
        Exception? caughtFailure = null;
        BackupSummary? summary = null;
        BackupWarnings? warnings = null;
        IYuccaRepositoryApi? api = null;
        Task<CloudOnlySkip?>? cloudOnlyScan = null;
        using var scanCancellation = new CancellationTokenSource();
        try
        {
            var server = await ServerInfoAsync(config.ServerUrl, cancellation);
            var madeApi = Environment.MakeApi(server.ApiRoot, token);
            api = madeApi;
            Report(madeApi, config, "Running backup", new() { ["repositoryId"] = repositoryId });
            Measure(config, deadline => madeApi.SubmitBackupStartAsync(repositoryId, deadline));
            await using var session = await StartSessionAsync(config, repositoryId, masterKey, token, cancellation);
            await Restic.RunAsync(ResticCommand.Unlock(session.Context), null, cancellation);
            cancellation.ThrowIfCancellationRequested();
            var folders = config.Folders.ToList();
            var excludes = config.Excludes.ToList();
            cloudOnlyScan = Task.Run(() => Environment.CloudOnlyScanner.Scan(folders, excludes, scanCancellation.Token), CancellationToken.None);
            var output = new BackupOutput();
            var result = await RunBackupCommandAsync(
                ResticCommand.Backup(session.Context, folders, excludes, config.Host),
                session.Proxy, config.Throttle, output, onActivity, cancellation);
            summary = output.Summary;
            if (result.ExitCode == ResticExitCode.Success)
            {
                status = BackupStatus.Complete;
            }
            else if (result.ExitCode == ResticExitCode.CouldNotReadSource)
            {
                status = BackupStatus.Warn;
                warnings = BackupWarnings.Collect(result.Stderr);
                message = warnings.Summary ?? ResticOutput.LastItemError(result.Stderr) ?? output.LastError ?? ResticCommand.FailureMessage(result);
            }
            else
            {
                status = BackupStatus.Failed;
                var detail = ResticCommand.FailureMessage(result);
                message = ErrorMessage.ResticText(detail, config.ServerDisplayName);
                failureDetail = detail;
            }

            var pruneInterrupted = false;
            var retention = config.SnapshotRetention;
            var forget = config.IsWriteOnce ? null : ResticCommand.Forget(session.Context, config.Host, retention);
            if (status == BackupStatus.Complete && !retention.IsKeepAll && !config.IsWriteOnce && forget is null)
            {
                message = Text.ErrorKeptOldSnapshots;
                Report(madeApi, config, "Skipped repository prune", new() { ["repositoryId"] = repositoryId, ["error"] = "invalid retention policy" });
            }

            if (status == BackupStatus.Complete && forget is not null)
            {
                onActivity(new EngineActivity.Pruning());
                Report(madeApi, config, "Running repository prune", new() { ["repositoryId"] = repositoryId, ["retentionPolicy"] = retention.TelemetryValue });
                string? pruneError = null;
                try
                {
                    var forgot = await Restic.RunAsync(forget, null, cancellation);
                    if (forgot.ExitCode != ResticExitCode.Success)
                    {
                        pruneError = ResticCommand.FailureMessage(forgot);
                        message = string.Format(CultureInfo.CurrentCulture, Text.ErrorCouldNotDeleteOldSnapshots, pruneError);
                    }
                }
                catch (OperationCanceledException)
                {
                    pruneInterrupted = true;
                    pruneError = "cancelled";
                    message = Text.ErrorDeletingOldSnapshotsStopped;
                }
                catch (Exception error)
                {
                    pruneError = error.ToString();
                    message = string.Format(CultureInfo.CurrentCulture, Text.ErrorCouldNotDeleteOldSnapshots, error.Message);
                }

                var pruneData = new Dictionary<string, object?> { ["repositoryId"] = repositoryId };
                if (pruneError is not null)
                {
                    pruneData["error"] = pruneError;
                }

                Report(madeApi, config, "Finished repository prune", pruneData);
            }

            if (status is BackupStatus.Complete or BackupStatus.Warn && !pruneInterrupted)
            {
                await ReportSizeAsync(session, madeApi, config, repositoryId, cancellation);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
            status = BackupStatus.Cancelled;
        }
        catch (Exception error)
        {
            status = BackupStatus.Failed;
            message = ErrorMessage.Text(error, config.ServerDisplayName) ?? ConnectionFailure.Unreachable.Message(config.ServerDisplayName);
            failureDetail = error.ToString();
            caughtFailure = error;
        }

        CloudOnlySkip? cloudOnlySkipped = null;
        if (cloudOnlyScan is not null)
        {
            if (status is BackupStatus.Complete or BackupStatus.Warn)
            {
                if (!cloudOnlyScan.IsCompleted)
                {
                    onActivity(new EngineActivity.Finishing(FinishingStep.CheckingCloudOnlyFiles));
                }

                try
                {
                    cloudOnlySkipped = await cloudOnlyScan.WaitAsync(cancellation);
                }
                catch (OperationCanceledException)
                {
                    await scanCancellation.CancelAsync();
                }
            }
            else
            {
                await scanCancellation.CancelAsync();
            }
        }

        var finishedAt = Environment.Now();
        var durationMs = stopwatch.ElapsedMilliseconds;
        var endStatus = status;
        var keptWarnings = status == BackupStatus.Warn && warnings is { Total: > 0 } ? warnings : null;
        if (api is { } endApi)
        {
            Measure(config, deadline => endApi.SubmitBackupEndAsync(repositoryId, endStatus, durationMs, deadline));
            var data = new Dictionary<string, object?>
            {
                ["repositoryId"] = repositoryId,
                ["lastBackupStatus"] = endStatus.ToString().ToLowerInvariant(),
                ["durationMs"] = durationMs,
            };
            if (cloudOnlySkipped is not null)
            {
                data["cloudOnlyFiles"] = cloudOnlySkipped.Count;
                data["cloudOnlySize"] = cloudOnlySkipped.TelemetrySizeBucket;
            }

            if (keptWarnings is not null)
            {
                data["warningCount"] = keptWarnings.Total;
            }

            if (status is BackupStatus.Failed or BackupStatus.Warn && message is not null)
            {
                data["error"] = failureDetail ?? message;
            }

            Report(endApi, config, "Backup finished", data);
        }
        else if (caughtFailure is not null)
        {
            Trace.TraceError(caughtFailure.ToString());
        }

        return new RunRecord
        {
            StartedAt = startedAt,
            FinishedAt = finishedAt,
            Status = status,
            SnapshotId = summary?.SnapshotId,
            FilesNew = summary?.FilesNew,
            DataAdded = summary?.DataAdded,
            FilesProcessed = summary?.TotalFilesProcessed,
            BytesProcessed = summary?.TotalBytesProcessed,
            Message = message,
            CloudOnlySkipped = cloudOnlySkipped is { Count: > 0 } ? cloudOnlySkipped : null,
            Warnings = keptWarnings,
        };
    }

    public async Task<long?> RepositorySizeAsync(AppConfig config, CancellationToken cancellation = default)
    {
        var repositoryId = config.RepositoryId ?? throw new EngineException(EngineError.NoRepository);
        await using var session = await StartSessionAsync(config, repositoryId, RequireMasterKey(), AccessToken(), cancellation);
        var stats = await Restic.RunAsync(ResticCommand.Stats(session.Context), null, cancellation);
        return stats.ExitCode == ResticExitCode.Success ? ResticOutput.ParseStatsTotalSize(stats.Stdout) : null;
    }

    private async Task ReportSizeAsync(Session session, IYuccaRepositoryApi api, AppConfig config, string repositoryId, CancellationToken cancellation)
    {
        object? statsError = null;
        try
        {
            var stats = await Restic.RunAsync(ResticCommand.Stats(session.Context), null, cancellation);
            if (stats.ExitCode == ResticExitCode.Success)
            {
                var totalSize = ResticOutput.ParseStatsTotalSize(stats.Stdout);
                Measure(config, async deadline =>
                {
                    try
                    {
                        await api.SubmitRepositorySizeAsync(repositoryId, totalSize, deadline);
                    }
                    catch (Exception error)
                    {
                        Report(api, config, "Failed to update repository metrics", new() { ["repositoryId"] = repositoryId, ["error"] = error });
                    }
                });
            }
            else
            {
                statsError = ResticCommand.FailureMessage(stats);
            }
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            statsError = error;
        }

        if (statsError is not null)
        {
            Report(api, config, "Failed to read repository stats", new() { ["repositoryId"] = repositoryId, ["error"] = statsError });
        }
    }

    private async Task<ResticResult> RunBackupCommandAsync(
        ResticInvocation invocation, IResticProxyHandle proxy, Throttle throttle, BackupOutput output, Action<EngineActivity> onActivity, CancellationToken cancellation)
    {
        var tracker = new BackingUpActivity(throttle);
        using var sampling = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        var clock = Stopwatch.StartNew();
        var sampler = Task.Run(async () =>
        {
            while (!sampling.IsCancellationRequested)
            {
                if (tracker.Sampled(proxy.UploadedBytes, clock.Elapsed.TotalSeconds) is { } activity)
                {
                    onActivity(activity);
                }

                try
                {
                    await Environment.Sleep(Environment.UploadTickInterval, sampling.Token);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        }, CancellationToken.None);
        try
        {
            return await Restic.RunAsync(invocation, line =>
            {
                var message = ResticOutput.ParseLine(line);
                if (message is ResticMessage.Status status)
                {
                    onActivity(tracker.Progressed(status.Progress, clock.Elapsed.TotalSeconds));
                }
                else
                {
                    output.Record(message);
                }
            }, cancellation);
        }
        finally
        {
            await sampling.CancelAsync();
            await sampler;
        }
    }

    public async Task<IReadOnlyList<Snapshot>> SnapshotsAsync(AppConfig config, CancellationToken cancellation = default)
    {
        var repositoryId = config.RepositoryId ?? throw new EngineException(EngineError.NoRepository);
        var token = AccessToken();
        await using var session = await StartSessionAsync(config, repositoryId, RequireMasterKey(), token, cancellation);
        var server = await ServerInfoAsync(config.ServerUrl, cancellation);
        var api = Environment.MakeApi(server.ApiRoot, token);
        ResticResult result;
        try
        {
            result = await Restic.RunAsync(ResticCommand.Snapshots(session.Context), null, cancellation);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            Report(api, config, "Failed to get repository snapshot listing", new() { ["repositoryId"] = repositoryId, ["error"] = error });
            throw;
        }

        if (result.ExitCode != ResticExitCode.Success)
        {
            var detail = ResticCommand.FailureMessage(result);
            Report(api, config, "Failed to get repository snapshot listing", new() { ["repositoryId"] = repositoryId, ["error"] = detail });
            throw new EngineException(EngineError.Restic, detail, result.ExitCode);
        }

        try
        {
            return ResticOutput.ParseSnapshots(result.Stdout).OrderByDescending(snapshot => snapshot.Time).ToList();
        }
        catch (UnreadableSnapshotTimeException error)
        {
            throw new FormatException(string.Format(CultureInfo.CurrentCulture, Text.ErrorSnapshotTimeUnreadable, error.ShortId), error);
        }
    }

    public async Task<IReadOnlyList<SnapshotEntry>> ListDirectoryAsync(AppConfig config, string snapshotId, string path, CancellationToken cancellation = default)
    {
        var repositoryId = config.RepositoryId ?? throw new EngineException(EngineError.NoRepository);
        var token = AccessToken();
        await using var session = await StartSessionAsync(config, repositoryId, RequireMasterKey(), token, cancellation);
        var result = await Restic.RunAsync(ResticCommand.Ls(session.Context, snapshotId, path), null, cancellation);
        if (result.ExitCode != ResticExitCode.Success)
        {
            var detail = ResticCommand.FailureMessage(result);
            var server = await ServerInfoAsync(config.ServerUrl, cancellation);
            var api = Environment.MakeApi(server.ApiRoot, token);
            Report(api, config, "Failed to list snapshot files", new() { ["repositoryId"] = repositoryId, ["snapshotId"] = snapshotId, ["error"] = detail });
            throw new EngineException(EngineError.Restic, detail, result.ExitCode);
        }

        return SnapshotListing.Parse(result.Stdout, path);
    }

    public Task<IReadOnlyList<string>> RestoreAsync(AppConfig config, string snapshotId, IReadOnlyList<RestoreItem> items, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default) =>
        RestoringAsync(config, snapshotId, items.Count == 0, new(), support, async (session, restored) =>
        {
            for (var index = 0; index < items.Count; index++)
            {
                var reporter = new RestoreReporter(index + 1, items.Count, new RestoreBatch.Folder(items[index]).Name, onActivity);
                restored.Add(await RestoreFolderAsync(items[index], snapshotId, session, reporter, restored.Names, cancellation));
            }
        }, cancellation);

    public Task<IReadOnlyList<string>> RestoreAsync(AppConfig config, string snapshotId, IReadOnlyList<SnapshotEntry> selection, string target, Action<EngineActivity> onActivity, ISupportLogSink? support = null, CancellationToken cancellation = default) =>
        RestoringAsync(config, snapshotId, selection.Count == 0, new() { ["itemCount"] = selection.Count }, support, async (session, restored) =>
        {
            var batches = RestorePlan.Batches(selection, target);
            for (var index = 0; index < batches.Count; index++)
            {
                var reporter = new RestoreReporter(index + 1, batches.Count, batches[index].Name, onActivity);
                switch (batches[index])
                {
                    case RestoreBatch.Folder folder:
                        restored.Add(await RestoreFolderAsync(folder.Item, snapshotId, session, reporter, restored.Names, cancellation));
                        break;
                    case RestoreBatch.Children children:
                        await RestoreChildrenAsync(children.Entries, children.Parent, target, snapshotId, session, reporter, restored, cancellation);
                        break;
                }
            }
        }, cancellation);

    private async Task<IReadOnlyList<string>> RestoringAsync(
        AppConfig config, string snapshotId, bool isEmpty, Dictionary<string, object?> extraData, ISupportLogSink? support, Func<Session, RestoredItems, Task> body, CancellationToken cancellation)
    {
        var repositoryId = config.RepositoryId ?? throw new EngineException(EngineError.NoRepository);
        if (isEmpty) throw new EngineException(EngineError.NoFolders);
        var token = AccessToken();
        var masterKey = RequireMasterKey();
        using var claim = Claim(support);
        await using var session = await StartSessionAsync(config, repositoryId, masterKey, token, cancellation);
        var server = await ServerInfoAsync(config.ServerUrl, cancellation);
        var api = Environment.MakeApi(server.ApiRoot, token);
        var data = new Dictionary<string, object?>(extraData) { ["repositoryId"] = repositoryId, ["snapshotId"] = snapshotId };
        Report(api, config, "Running repository snapshot restore", data);
        var restored = new RestoredItems();
        try
        {
            await body(session, restored);
        }
        catch (RestoreIncompleteException incomplete)
        {
            data["error"] = incomplete.Cause.Message;
            Report(api, config, "Finished repository snapshot restore", data);
            throw new RestoreIncompleteException(incomplete.Cause, restored.Paths, incomplete.LeftoverStaging);
        }
        catch (Exception error) when (restored.Paths.Count > 0)
        {
            data["error"] = error is OperationCanceledException ? "cancelled" : error.Message;
            Report(api, config, "Finished repository snapshot restore", data);
            throw new RestoreIncompleteException(error, restored.Paths, null);
        }
        catch (Exception error)
        {
            data["error"] = error is OperationCanceledException ? "cancelled" : error.Message;
            Report(api, config, "Finished repository snapshot restore", data);
            throw;
        }

        Report(api, config, "Finished repository snapshot restore", data);
        return restored.Paths;
    }

    private async Task<string> RestoreFolderAsync(RestoreItem item, string snapshotId, Session session, RestoreReporter reporter, IReadOnlySet<string> taken, CancellationToken cancellation)
    {
        var target = RestorePlan.ClaimTarget(item, taken, Environment.CreateRestoreDirectory);
        await RunRestoreAsync(ResticCommand.Restore(session.Context, snapshotId, target, item.SnapshotPath), reporter, cancellation);
        reporter.Finished();
        return target;
    }

    private async Task RestoreChildrenAsync(
        IReadOnlyList<SnapshotEntry> children, string parent, string target, string snapshotId, Session session, RestoreReporter reporter, RestoredItems restored, CancellationToken cancellation)
    {
        var staging = RestorePlan.ClaimStaging(target, children.Select(child => RestorePlan.NameKey(child.Name)).ToHashSet(), Environment.CreateRestoreStaging);
        try
        {
            await RunRestoreAsync(ResticCommand.Restore(session.Context, snapshotId, staging, parent, children.Select(child => child.Name).ToList()), reporter, cancellation);
            foreach (var child in children)
            {
                var source = Path.Combine(staging, child.Name);
                restored.Add(RestorePlan.ClaimName(child, target, restored.Names, destination => Environment.MoveRestoredItem(source, destination)));
            }
        }
        catch (Exception error)
        {
            RemoveStaging(staging, error);
            throw;
        }

        RemoveStaging(staging, null);
        reporter.Finished();
    }

    private void RemoveStaging(string staging, Exception? failure)
    {
        try
        {
            Environment.RemoveRestoreStaging(staging);
        }
        catch (Exception error)
        {
            throw new RestoreIncompleteException(failure ?? error, [], staging);
        }
    }

    private async Task RunRestoreAsync(ResticInvocation invocation, RestoreReporter reporter, CancellationToken cancellation)
    {
        reporter.Started();
        var result = await Restic.RunAsync(invocation, reporter.Received, cancellation);
        if (result.ExitCode != ResticExitCode.Success)
        {
            throw new EngineException(EngineError.Restic, ResticCommand.FailureMessage(result), result.ExitCode);
        }
    }

    public async Task<IReadOnlyList<RemoteRepository>> WindowsRepositoriesAsync(AppConfig config, CancellationToken cancellation = default)
    {
        var token = AccessToken();
        var server = await ServerInfoAsync(config.ServerUrl, cancellation);
        var repositories = await Environment.MakeApi(server.ApiRoot, token).ListRepositoriesAsync(cancellation);
        return repositories
            .Where(repository => repository.ConnectionType == YuccaClient.ConnectionType)
            .OrderByDescending(repository => string.Equals(repository.Name, config.Host, StringComparison.OrdinalIgnoreCase))
            .ThenByDescending(repository => repository.LastBackup.HasValue)
            .ThenByDescending(repository => repository.LastBackup)
            .ThenBy(repository => repository.Name, StringComparer.Ordinal)
            .ToList();
    }

    public async Task<IReadOnlyList<RemoteRepository>> OtherRepositoriesAsync(AppConfig config, CancellationToken cancellation = default)
    {
        var token = AccessToken();
        var server = await ServerInfoAsync(config.ServerUrl, cancellation);
        var repositories = await Environment.MakeApi(server.ApiRoot, token).ListRepositoriesAsync(cancellation);
        return repositories.Where(repository => repository.Id != config.RepositoryId).OrderBy(repository => repository.Name).ToList();
    }

    public async Task<bool> VerifyMasterKeyAsync(string masterKey, AppConfig config, string repositoryId, CancellationToken cancellation = default)
    {
        var normalized = RepositoryKeys.NormalizedMasterKey(masterKey) ?? throw new InvalidMasterKeyException();
        var token = AccessToken();
        using var claim = Claim();
        await using var session = await StartSessionAsync(config, repositoryId, normalized, token, cancellation);
        var result = await Restic.RunAsync(ResticCommand.CatConfig(session.Context), null, cancellation);
        return result.ExitCode switch
        {
            ResticExitCode.Success => true,
            ResticExitCode.WrongPassword => false,
            _ => throw new EngineException(EngineError.Restic, ResticCommand.FailureMessage(result), result.ExitCode),
        };
    }

    public async Task<ExistingBackupUnlock> UnlockExistingRepositoryAsync(string repositoryId, string key, bool isStored, AppConfig config, CancellationToken cancellation = default)
    {
        var verified = await VerifyMasterKeyAsync(key, config, repositoryId, cancellation);
        if (!verified) return isStored ? ExistingBackupUnlock.NeedsKey : ExistingBackupUnlock.WrongKey;
        ImportMasterKey(key);
        return ExistingBackupUnlock.Unlocked;
    }

    public async Task CheckKeyAsync(string key, IReadOnlyList<string> repositoryIds, AppConfig config, Action<string, StoredKeyCheck> onCheck, CancellationToken cancellation = default)
    {
        foreach (var repositoryId in repositoryIds)
        {
            if (cancellation.IsCancellationRequested) return;
            onCheck(repositoryId, StoredKeyCheck.Checking);
            StoredKeyCheck check;
            try
            {
                var verified = await VerifyMasterKeyAsync(key, config, repositoryId, cancellation);
                check = verified ? StoredKeyCheck.Opens : StoredKeyCheck.DoesNotOpen;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception)
            {
                check = StoredKeyCheck.Unknown;
            }

            onCheck(repositoryId, check);
        }
    }

    internal string AccessToken() => Environment.Secrets.Get(SecretKey.AccessToken) ?? throw new EngineException(EngineError.NotLoggedIn);

    internal string RequireMasterKey() => StoredMasterKey() ?? throw new EngineException(EngineError.MissingMasterKey);

    internal async Task<ServerInfo> ServerInfoAsync(Uri url, CancellationToken cancellation)
    {
        lock (gate)
        {
            if (serverCache.TryGetValue(url, out var cached)) return cached;
        }

        var server = await Environment.Discover(url, cancellation);
        lock (gate)
        {
            serverCache[url] = server;
        }

        return server;
    }

    internal void Report(IYuccaRepositoryApi api, AppConfig config, string summary, Dictionary<string, object?> data)
    {
        if (config.TelemetryConsentedAt is null) return;
        var log = Environment.Telemetry.Log(summary, data, Environment.AppVersion);
        outbox.Enqueue(deadline => api.SubmitStructuredLogAsync(log, deadline));
    }

    private void Measure(AppConfig config, Func<CancellationToken, Task> submit)
    {
        if (config.TelemetryConsentedAt is null) return;
        outbox.Enqueue(submit);
    }

    private IResticExecuting Restic => support is { } sink ? new RecordingRestic(Environment.Restic, sink) : Environment.Restic;

    internal IDisposable Claim(ISupportLogSink? support = null)
    {
        lock (gate)
        {
            if (running) throw new EngineException(EngineError.Busy);
            running = true;
            this.support = support;
        }

        return new Release(this);
    }

    private sealed class Release(BackupEngine engine) : IDisposable
    {
        public void Dispose()
        {
            lock (engine.gate)
            {
                engine.running = false;
                engine.support = null;
            }
        }
    }

    private async Task<bool> IsFutoResticAsync()
    {
        if (futoRestic is { } cached) return cached;
        try
        {
            var result = await Restic.RunAsync(ResticCommand.Version());
            futoRestic = result.ExitCode == ResticExitCode.Success && ResticOutput.ParseVersion(result.Stdout).Contains("+futo.");
        }
        catch (Exception)
        {
            futoRestic = false;
        }

        return futoRestic.Value;
    }

    internal async Task<Session> StartSessionAsync(AppConfig config, string repositoryId, string masterKey, string token, CancellationToken cancellation)
    {
        var server = await ServerInfoAsync(config.ServerUrl, cancellation);
        var proxy = await Environment.ProxyLauncher.StartAsync(server.ApiRoot, config.Throttle, cancellation);
        try
        {
            var connections = ResolvedConnections(config, server, Environment.ProcessorCount);
            var isFutoRestic = await IsFutoResticAsync();
            var context = new ResticContext(
                ResticProxyUrls.Repository(proxy.Address, repositoryId, token),
                RepositoryKeys.Password(masterKey, repositoryId),
                Environment.CacheDirectory,
                connections,
                Math.Clamp(server.ResticPackSizeMiB, ResticContext.MinPackSizeMiB, ResticContext.MaxPackSizeMiB),
                isFutoRestic ? 64 : null,
                config.ReadConcurrency is { } read ? Math.Max(1, read) : null);
            var watch = Environment.WatchNetworkChanges(() => _ = proxy.NetworkChangedAsync());
            liveProxy = proxy;
            return new Session(proxy, context, watch);
        }
        catch
        {
            await proxy.DisposeAsync();
            throw;
        }
    }

    public static int ResolvedConnections(AppConfig config, ServerInfo? server, int processorCount) =>
        config.UploadConnections is { } chosen ? Math.Max(1, chosen)
        : server is not null && int.TryParse(server.ConnectionsMath.Trim(), out var math) ? Math.Max(1, math)
        : Math.Max(1, processorCount);
}

internal sealed class BackingUpActivity(Throttle throttle)
{
    private readonly Lock gate = new();
    private readonly UploadSpeedMeter meter = new(throttle);
    private readonly TimeLeftEstimate estimate = new();
    private BackupProgress? progress;

    public EngineActivity Progressed(BackupProgress reported, double atSeconds)
    {
        lock (gate)
        {
            var estimated = reported with { SecondsRemaining = estimate.SecondsLeft(reported, atSeconds) };
            progress = estimated;
            return new EngineActivity.BackingUp(estimated, meter.Speed);
        }
    }

    public EngineActivity? Sampled(long uploadedBytes, double atSeconds)
    {
        lock (gate)
        {
            var speed = meter.Record(uploadedBytes, atSeconds);
            return progress is null ? null : new EngineActivity.BackingUp(progress, speed);
        }
    }
}

internal sealed class RestoreReporter(int part, int partCount, string name, Action<EngineActivity> onActivity)
{
    private readonly RestoreStep step = new(part, partCount, name);
    private RestoreProgress? summary;

    public void Started() => onActivity(new EngineActivity.Restoring(step));

    public void Received(string line)
    {
        switch (ResticOutput.ParseRestoreLine(line))
        {
            case (false, var progress):
                onActivity(new EngineActivity.Restoring(step with { Progress = progress }));
                break;
            case (true, var progress):
                summary = progress;
                break;
        }
    }

    public void Finished()
    {
        if (summary is { } done)
        {
            onActivity(new EngineActivity.Restoring(step with { Progress = done }));
        }
    }
}

internal sealed class BackupOutput
{
    private readonly Lock gate = new();
    private BackupSummary? summary;
    private string? lastError;

    public BackupSummary? Summary
    {
        get
        {
            lock (gate)
            {
                return summary;
            }
        }
    }

    public string? LastError
    {
        get
        {
            lock (gate)
            {
                return lastError;
            }
        }
    }

    public void Record(ResticMessage message)
    {
        lock (gate)
        {
            switch (message)
            {
                case ResticMessage.Summary value:
                    summary = value.Value;
                    break;
                case ResticMessage.Error error:
                    lastError = error.Message;
                    break;
            }
        }
    }
}
