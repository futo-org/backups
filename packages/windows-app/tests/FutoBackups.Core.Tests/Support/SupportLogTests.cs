using System.IO.Compression;
using System.Text;
using System.Text.Json;

using FutoBackups.Core.Api;
using FutoBackups.Core.Support;

namespace FutoBackups.Core.Tests.Support;

public sealed class SupportLogTests : IDisposable
{
    private static readonly DateTimeOffset Noon = new(2026, 11, 27, 12, 0, 0, TimeSpan.Zero);
    private static readonly SupportSession Session = new("session-1", "token-1", "https://logs.example/batch", Noon.AddHours(1));

    private readonly string directory = Path.Combine(Path.GetTempPath(), $"futo-support-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }

    private sealed class StreamerApi : IAccountApi
    {
        public Queue<int> Statuses { get; } = new();

        public List<(string Token, int Sequence, bool Final, string Text)> Batches { get; } = [];

        public int Refreshes { get; private set; }

        public Task<int> SendSupportBatchAsync(Uri url, string token, byte[] gzippedLines, int sequence, int droppedLines, bool final, CancellationToken cancellation = default)
        {
            using var gzip = new GZipStream(new MemoryStream(gzippedLines), CompressionMode.Decompress);
            using var reader = new StreamReader(gzip, Encoding.UTF8);
            Batches.Add((token, sequence, final, reader.ReadToEnd()));
            return Task.FromResult(Statuses.Count > 0 ? Statuses.Dequeue() : 202);
        }

        public Task<SupportSession> RefreshSupportSessionAsync(string sessionId, CancellationToken cancellation = default)
        {
            Refreshes++;
            return Task.FromResult(Session with { Token = $"token-{Refreshes + 1}" });
        }

        public Task<AuthInfo> MeAsync(CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task LogoutAsync(CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<IReadOnlyList<RemoteRepository>> ListRepositoriesAsync(CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<RemoteRepository> UpdateRepositoryAsync(string repositoryId, string? name = null, bool? worm = null, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<Uri> CreateTicketAsync(string action, string repositoryId, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task DeleteConnectionAsync(string id, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task SubmitStructuredLogAsync(StructuredLog log, CancellationToken cancellation = default) => throw new NotSupportedException();

        public Task<SupportSession> CreateSupportSessionAsync(string jobId, string jobName, bool includesPaths, string clientVersion, CancellationToken cancellation = default) => throw new NotSupportedException();
    }

    [Fact]
    public async Task LinesAreWrittenToTheFileWithPathsRedacted()
    {
        var path = Path.Combine(directory, "backup.log");
        var log = new SupportLog(path, new PathRedactor(Enumerable.Repeat((byte)1, 32).ToArray()), null, () => Noon);

        log.Add("stderr", "backup", @"open C:\Users\me\Tax return.docx: Access is denied.");
        await log.DisposeAsync();

        using var line = JsonDocument.Parse(Assert.Single(await File.ReadAllLinesAsync(path, TestContext.Current.CancellationToken)));
        Assert.Equal("stderr", line.RootElement.GetProperty("stream").GetString());
        Assert.Equal("backup", line.RootElement.GetProperty("command").GetString());
        Assert.Matches(@"^open <path:[0-9a-f]{12}\.docx>: Access is denied\.$", line.RootElement.GetProperty("message").GetString());
        Assert.Null(log.Code);
    }

    [Fact]
    public async Task FinishingSendsTheRemainingLinesAsTheFinalBatch()
    {
        var api = new StreamerApi();
        using var uploader = new SupportLogUploader(api, Session);
        var log = new SupportLog(Path.Combine(directory, "backup.log"), null, uploader, () => Noon);

        log.Add("meta", "backup", "started");
        log.Add("meta", "backup", "exited with code 0");
        await log.DisposeAsync();

        var batch = Assert.Single(api.Batches);
        Assert.Equal("session-1", log.Code);
        Assert.True(batch.Final);
        Assert.Equal(0, batch.Sequence);
        Assert.Equal(2, batch.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries).Length);
    }

    [Fact]
    public async Task AnExpiredSessionIsRefreshedAndTheBatchSentAgain()
    {
        var api = new StreamerApi();
        api.Statuses.Enqueue(401);
        using var uploader = new SupportLogUploader(api, Session);

        uploader.Add("line");
        await uploader.FinishAsync();

        Assert.Equal(1, api.Refreshes);
        Assert.Equal(["token-1", "token-2"], api.Batches.Select(batch => batch.Token));
    }

    [Fact]
    public async Task ARejectedBatchIsNotRetried()
    {
        var api = new StreamerApi();
        api.Statuses.Enqueue(413);
        using var uploader = new SupportLogUploader(api, Session);

        uploader.Add("line");
        await uploader.FinishAsync();

        Assert.Single(api.Batches);
    }
}
