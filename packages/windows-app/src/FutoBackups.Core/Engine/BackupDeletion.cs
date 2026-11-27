using FutoBackups.Core.Api;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Engine;

public static class TicketActions
{
    public const string DeleteRepository = "repository.delete";

    public const string DisableWriteOnce = "repository.disable-worm";
}

public abstract record BackupDeletionStep
{
    public sealed record ConfirmingInBrowser(Uri Url) : BackupDeletionStep;

    public sealed record RemovingThisPc : BackupDeletionStep;
}

public abstract record BackupDeletionResult
{
    public sealed record Deleted : BackupDeletionResult;

    public sealed record ConnectionKeepsRepositories(IReadOnlyList<RemoteRepository> Repositories) : BackupDeletionResult;
}

public enum BackupDeletionError
{
    NoConnection,
    TimedOut,
    ConnectionNotDeleted,
    ConnectionUnreachable,
}

public sealed class BackupDeletionException(BackupDeletionError error, string? detail = null) : Exception(error switch
{
    BackupDeletionError.NoConnection => Text.ErrorDeleteNoConnection,
    BackupDeletionError.TimedOut => Text.ErrorDeleteTimedOut,
    BackupDeletionError.ConnectionUnreachable => detail ?? Text.ErrorDeleteConnectionUnreachable,
    _ => Text.ErrorDeleteConnectionNotDeleted,
})
{
    public BackupDeletionError Error { get; } = error;

    public string? Detail { get; } = detail;
}

public sealed class BackupDeletion(IAccountApi api, Func<Uri, Task> openBrowser, Telemetry? telemetry, string version, Func<TimeSpan, CancellationToken, Task>? sleep = null, TimeSpan? pollInterval = null, TimeSpan? timeout = null)
{
    public static readonly TimeSpan DefaultPollInterval = TimeSpan.FromSeconds(4);
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(15);

    private readonly Func<TimeSpan, CancellationToken, Task> sleep = sleep ?? Task.Delay;
    private readonly TimeSpan pollInterval = pollInterval ?? DefaultPollInterval;
    private readonly TimeSpan timeout = timeout ?? DefaultTimeout;

    public async Task<BackupDeletionResult> RunAsync(string repositoryId, Func<BackupDeletionStep, Task> onStep, CancellationToken cancellation = default)
    {
        var me = await api.MeAsync(cancellation);
        var connectionId = me.ConnectionId ?? throw new BackupDeletionException(BackupDeletionError.NoConnection);
        if (await IsListedAsync(repositoryId, cancellation))
        {
            await ReportAsync("Running repository deletion", new() { ["repositoryId"] = repositoryId });
            try
            {
                await DeleteRepositoryAsync(repositoryId, onStep, cancellation);
            }
            catch (Exception error)
            {
                await ReportAsync("Finished repository deletion", new()
                {
                    ["repositoryId"] = repositoryId,
                    ["error"] = error switch { OperationCanceledException => "cancelled", BackupDeletionException { Error: BackupDeletionError.TimedOut } => "timed out", _ => error.Message },
                });
                throw;
            }

            await ReportAsync("Finished repository deletion", new() { ["repositoryId"] = repositoryId });
            await ReportAsync("Deleted repository", new() { ["repositoryId"] = repositoryId });
        }

        await onStep(new BackupDeletionStep.RemovingThisPc());
        return await DeleteConnectionAsync(connectionId, cancellation);
    }

    private async Task DeleteRepositoryAsync(string repositoryId, Func<BackupDeletionStep, Task> onStep, CancellationToken cancellation)
    {
        var url = await api.CreateTicketAsync(TicketActions.DeleteRepository, repositoryId, cancellation);
        await openBrowser(url);
        await onStep(new BackupDeletionStep.ConfirmingInBrowser(url));
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (true)
        {
            await sleep(pollInterval, cancellation);
            if (await IsGoneAsync(repositoryId, cancellation)) return;
            if (DateTimeOffset.UtcNow >= deadline) throw new BackupDeletionException(BackupDeletionError.TimedOut);
        }
    }

    private async Task<BackupDeletionResult> DeleteConnectionAsync(string connectionId, CancellationToken cancellation)
    {
        try
        {
            await api.DeleteConnectionAsync(connectionId, cancellation);
            return new BackupDeletionResult.Deleted();
        }
        catch (YuccaApiException error) when (error.StatusCode == 400)
        {
            IReadOnlyList<RemoteRepository> owned;
            try
            {
                var repositories = await api.ListRepositoriesAsync(cancellation);
                owned = repositories.Where(repository => repository.ConnectionId == connectionId).ToList();
            }
            catch (Exception)
            {
                owned = [];
            }

            if (owned.Count > 0)
            {
                await ReportAsync("Failed to delete connection", new() { ["connectionId"] = connectionId, ["repositories"] = owned.Select(repository => repository.Id).ToList() });
                return new BackupDeletionResult.ConnectionKeepsRepositories(owned);
            }

            throw new BackupDeletionException(BackupDeletionError.ConnectionNotDeleted, error.Response ?? string.Empty);
        }
        catch (Exception error) when (error is not OperationCanceledException and not YuccaApiException { StatusCode: 401 })
        {
            if (ConnectionFailures.From(error) is { } failure) throw new BackupDeletionException(BackupDeletionError.ConnectionUnreachable, failure.Message(Text.CommonFutoCloud));
            throw new BackupDeletionException(BackupDeletionError.ConnectionNotDeleted, error.Message);
        }
    }

    private async Task<bool> IsListedAsync(string repositoryId, CancellationToken cancellation)
    {
        var repositories = await api.ListRepositoriesAsync(cancellation);
        return repositories.Any(repository => repository.Id == repositoryId);
    }

    private async Task<bool> IsGoneAsync(string repositoryId, CancellationToken cancellation)
    {
        try
        {
            var listed = await IsListedAsync(repositoryId, cancellation);
            return !listed;
        }
        catch (YuccaApiException error) when (error.StatusCode == 401)
        {
            throw;
        }
        catch (Exception) when (!cancellation.IsCancellationRequested)
        {
            return false;
        }
    }

    private async Task ReportAsync(string summary, Dictionary<string, object?> data)
    {
        if (telemetry is null) return;
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            await api.SubmitStructuredLogAsync(telemetry.Log(summary, data, version), deadline.Token);
        }
        catch (Exception)
        {
        }
    }
}

public sealed record LocalFiles(string ConfigFile, string CacheDirectory)
{
    public static LocalFiles Standard() => new(
        ConfigStore.Standard().FilePath,
        Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.LocalApplicationData), "FUTO Backups", "Cache"));

    public string SupportLogDirectory => Path.Combine(Path.GetDirectoryName(ConfigFile) ?? CacheDirectory, "Support Logs");
}

public enum LocalResetItem
{
    CredentialManagerItems,
    Settings,
    Cache,
}

public static class LocalResetItems
{
    public static string Title(this LocalResetItem item) => item switch
    {
        LocalResetItem.CredentialManagerItems => Text.ResetCredentialManagerItems,
        LocalResetItem.Settings => Text.ResetSettings,
        _ => Text.ResetCache,
    };
}

public sealed class PcReset(LocalFiles files, ISecretStore secrets)
{
    public async Task<IReadOnlyList<LocalResetItem>> RunAsync(IAccountApi? signingOut = null, StructuredLog? log = null)
    {
        if (signingOut is not null)
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            try
            {
                if (log is not null)
                {
                    await signingOut.SubmitStructuredLogAsync(log, deadline.Token);
                }

                await signingOut.LogoutAsync(deadline.Token);
            }
            catch (Exception)
            {
            }
        }

        var failed = new List<LocalResetItem>();
        foreach (var key in Enum.GetValues<SecretKey>())
        {
            try
            {
                secrets.Delete(key);
            }
            catch (Exception)
            {
                if (!failed.Contains(LocalResetItem.CredentialManagerItems))
                {
                    failed.Add(LocalResetItem.CredentialManagerItems);
                }
            }
        }

        var directory = Path.GetDirectoryName(files.ConfigFile)!;
        var corrupt = Directory.Exists(directory) ? Directory.EnumerateFiles(directory, Path.GetFileName(files.ConfigFile) + ".corrupt-*") : [];
        if (!new[] { files.ConfigFile }.Concat(corrupt).All(Remove))
        {
            failed.Add(LocalResetItem.Settings);
        }

        if (!Remove(files.CacheDirectory))
        {
            failed.Add(LocalResetItem.Cache);
        }

        return failed;
    }

    private static bool Remove(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, true);
            }
            else if (File.Exists(path))
            {
                File.Delete(path);
            }

            return true;
        }
        catch (Exception)
        {
            return !Path.Exists(path);
        }
    }
}
