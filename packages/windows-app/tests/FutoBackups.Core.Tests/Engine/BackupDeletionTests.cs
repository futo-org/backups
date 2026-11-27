using FutoBackups.Core.Api;
using FutoBackups.Core.Engine;
using FutoBackups.Core.State;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Tests.Engine;

public sealed class BackupDeletionTests : IDisposable
{
    private const string RepositoryId = "repo-1";
    private static readonly Uri Ticket = new("https://futo.cloud/confirm");

    private readonly string directory = Path.Combine(Path.GetTempPath(), $"futo-reset-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }

    private sealed class Account : IAccountApi
    {
        public string? ConnectionId { get; init; } = "connection-1";

        public Queue<IReadOnlyList<RemoteRepository>> Listings { get; } = new();

        public Exception? DeleteConnectionError { get; init; }

        public List<string> Calls { get; } = [];

        public Task<AuthInfo> MeAsync(CancellationToken cancellation = default) => Task.FromResult(new AuthInfo("user", "Sam", "sam@example.com", ConnectionId));

        public Task<IReadOnlyList<RemoteRepository>> ListRepositoriesAsync(CancellationToken cancellation = default) =>
            Task.FromResult(Listings.Count > 1 ? Listings.Dequeue() : Listings.Peek());

        public Task<Uri> CreateTicketAsync(string action, string repositoryId, CancellationToken cancellation = default)
        {
            Calls.Add($"ticket {action} {repositoryId}");
            return Task.FromResult(Ticket);
        }

        public Task DeleteConnectionAsync(string id, CancellationToken cancellation = default)
        {
            Calls.Add($"delete connection {id}");
            return DeleteConnectionError is { } error ? Task.FromException(error) : Task.CompletedTask;
        }

        public Task LogoutAsync(CancellationToken cancellation = default)
        {
            Calls.Add("logout");
            return Task.CompletedTask;
        }

        public Task SubmitStructuredLogAsync(StructuredLog log, CancellationToken cancellation = default)
        {
            Calls.Add($"log {log.Summary}");
            return Task.CompletedTask;
        }

        public Task<RemoteRepository> UpdateRepositoryAsync(string repositoryId, string? name = null, bool? worm = null, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<SupportSession> CreateSupportSessionAsync(string jobId, string jobName, bool includesPaths, string clientVersion, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<SupportSession> RefreshSupportSessionAsync(string sessionId, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<int> SendSupportBatchAsync(Uri url, string token, byte[] gzippedLines, int sequence, int droppedLines, bool final, CancellationToken cancellation = default) => throw new NotSupportedException();
    }

    private sealed class RefusingSecretStore : ISecretStore
    {
        public string? Get(SecretKey key) => null;

        public void Set(SecretKey key, string value)
        {
        }

        public void Delete(SecretKey key) => throw new InvalidOperationException("locked");
    }

    private static RemoteRepository Repository(string id = RepositoryId) => new(id, "test-pc", false, "connection-1");

    private static BackupDeletion Deletion(Account account, List<Uri> opened, TimeSpan? timeout = null) =>
        new(account, url =>
        {
            opened.Add(url);
            return Task.CompletedTask;
        }, null, "1.0.0", (_, _) => Task.CompletedTask, TimeSpan.Zero, timeout);

    [Fact]
    public async Task AListedBackupIsConfirmedInTheBrowserThenThisPcIsRemoved()
    {
        var account = new Account();
        account.Listings.Enqueue([Repository()]);
        account.Listings.Enqueue([Repository()]);
        account.Listings.Enqueue([]);
        var opened = new List<Uri>();
        var steps = new List<BackupDeletionStep>();

        var result = await Deletion(account, opened).RunAsync(RepositoryId, step =>
        {
            steps.Add(step);
            return Task.CompletedTask;
        }, TestContext.Current.CancellationToken);

        Assert.IsType<BackupDeletionResult.Deleted>(result);
        Assert.Equal([Ticket], opened);
        Assert.Equal([new BackupDeletionStep.ConfirmingInBrowser(Ticket), new BackupDeletionStep.RemovingThisPc()], steps);
        Assert.Equal(["ticket repository.delete repo-1", "delete connection connection-1"], account.Calls);
    }

    [Fact]
    public async Task ABackupAlreadyGoneOnlyRemovesThisPc()
    {
        var account = new Account();
        account.Listings.Enqueue([]);
        var opened = new List<Uri>();

        await Deletion(account, opened).RunAsync(RepositoryId, _ => Task.CompletedTask, TestContext.Current.CancellationToken);

        Assert.Empty(opened);
        Assert.Equal(["delete connection connection-1"], account.Calls);
    }

    [Fact]
    public async Task AConnectionThatStillOwnsBackupsIsKeptAndTheyAreNamed()
    {
        var other = Repository("repo-2");
        var account = new Account { DeleteConnectionError = new YuccaApiException("refused", 400, "has repositories", new Dictionary<string, IEnumerable<string>>(), null) };
        account.Listings.Enqueue([other]);

        var result = await Deletion(account, []).RunAsync(RepositoryId, _ => Task.CompletedTask, TestContext.Current.CancellationToken);

        Assert.Equal([other], Assert.IsType<BackupDeletionResult.ConnectionKeepsRepositories>(result).Repositories);
    }

    [Fact]
    public async Task AnAccountWithoutAConnectionCannotRemoveThisPc()
    {
        var account = new Account { ConnectionId = null };
        account.Listings.Enqueue([]);

        var error = await Assert.ThrowsAsync<BackupDeletionException>(() => Deletion(account, []).RunAsync(RepositoryId, _ => Task.CompletedTask, TestContext.Current.CancellationToken));

        Assert.Equal(BackupDeletionError.NoConnection, error.Error);
    }

    [Fact]
    public async Task ABackupStillListedWhenTheTimeRunsOutTimesOut()
    {
        var account = new Account();
        account.Listings.Enqueue([Repository()]);

        var error = await Assert.ThrowsAsync<BackupDeletionException>(() => Deletion(account, [], TimeSpan.Zero).RunAsync(RepositoryId, _ => Task.CompletedTask, TestContext.Current.CancellationToken));

        Assert.Equal(BackupDeletionError.TimedOut, error.Error);
        Assert.DoesNotContain("delete connection connection-1", account.Calls);
    }

    [Fact]
    public async Task ResettingThisPcSignsOutThenRemovesSettingsCacheAndSecrets()
    {
        var files = new LocalFiles(Path.Combine(directory, "config.json"), Path.Combine(directory, "Cache"));
        Directory.CreateDirectory(files.CacheDirectory);
        await File.WriteAllTextAsync(files.ConfigFile, "{}", TestContext.Current.CancellationToken);
        await File.WriteAllTextAsync(files.ConfigFile + ".corrupt-2026-11-27T101530Z", "{", TestContext.Current.CancellationToken);
        var secrets = new InMemorySecretStore(new() { [SecretKey.AccessToken] = "token", [SecretKey.MasterKey] = "key" });
        var account = new Account();

        var failed = await new PcReset(files, secrets).RunAsync(account, new StructuredLog("Reset", new Dictionary<string, object?>()));

        Assert.Empty(failed);
        Assert.Equal(["log Reset", "logout"], account.Calls);
        Assert.Empty(Directory.EnumerateFileSystemEntries(directory));
        Assert.Null(secrets.Get(SecretKey.AccessToken));
        Assert.Null(secrets.Get(SecretKey.MasterKey));
    }

    [Fact]
    public async Task ASecretThatCannotBeRemovedIsReportedAndTheRestStillGoes()
    {
        var files = new LocalFiles(Path.Combine(directory, "config.json"), Path.Combine(directory, "Cache"));
        Directory.CreateDirectory(directory);
        await File.WriteAllTextAsync(files.ConfigFile, "{}", TestContext.Current.CancellationToken);

        var failed = await new PcReset(files, new RefusingSecretStore()).RunAsync();

        Assert.Equal([LocalResetItem.CredentialManagerItems], failed);
        Assert.False(File.Exists(files.ConfigFile));
    }
}
