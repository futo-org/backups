using System.Globalization;
using System.Net.Http.Headers;

using FutoBackups.Core.State;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Api;

public sealed record DeviceAuthorization(
    string DeviceCode,
    string UserCode,
    string VerificationUri,
    string? VerificationUriComplete,
    long ExpiresIn,
    long? Interval);

public sealed record AuthInfo(string Id, string Name, string Email, string? ConnectionId = null, IReadOnlyDictionary<string, bool>? Features = null)
{
    public const string SupportLogStreaming = "support-log-streaming";

    public bool StreamsSupportLogs => Features?.GetValueOrDefault(SupportLogStreaming) == true;
}

public sealed record SupportSession(string Id, string Token, string Url, DateTimeOffset ExpiresAt);

public sealed record RemoteRepository(string Id, string Name, bool Worm, string? ConnectionId = null, string? ConnectionType = null, long? SizeBytes = null, DateTimeOffset? LastBackup = null);

public sealed record StructuredLog(string Summary, IReadOnlyDictionary<string, object?> Data);

public interface IYuccaRepositoryApi
{
    Task<IReadOnlyList<RemoteRepository>> ListRepositoriesAsync(CancellationToken cancellation = default);

    Task<RemoteRepository> CreateRepositoryAsync(string name, CancellationToken cancellation = default);

    Task SubmitBackupStartAsync(string repositoryId, CancellationToken cancellation = default);

    Task SubmitBackupEndAsync(string repositoryId, BackupStatus status, long durationMs, CancellationToken cancellation = default);

    Task SubmitRepositorySizeAsync(string repositoryId, long sizeBytes, CancellationToken cancellation = default);

    Task SubmitStructuredLogAsync(StructuredLog log, CancellationToken cancellation = default);
}

public sealed class YuccaClient(Uri apiRoot, HttpClient http, string? accessToken = null, Func<TimeSpan, CancellationToken, Task>? sleep = null) : IYuccaRepositoryApi
{
    public const string ConnectionType = "windows";

    private readonly YuccaApiClient api = new(http, apiRoot, accessToken);

    public Uri ApiRoot { get; } = apiRoot;

    public YuccaClient WithAccessToken(string token) => new(ApiRoot, http, token, sleep);

    public async Task<DeviceAuthorization> StartDeviceAuthorizationAsync(CancellationToken cancellation = default)
    {
        var start = await api.OidcDeviceAuthorizeAsync(cancellation);
        WebUrl(start.VerificationUri, "device verification URL");
        if (start.VerificationUriComplete is { } complete)
        {
            WebUrl(complete, "device verification URL");
        }

        return new DeviceAuthorization(start.DeviceCode, start.UserCode, start.VerificationUri, start.VerificationUriComplete, start.ExpiresIn, start.Interval);
    }

    public Task<string> WaitForTokenAsync(DeviceAuthorization authorization, string connectionName, CancellationToken cancellation = default)
    {
        var start = new DeviceFlowStartDto
        {
            DeviceCode = authorization.DeviceCode,
            UserCode = authorization.UserCode,
            VerificationUri = authorization.VerificationUri,
            VerificationUriComplete = authorization.VerificationUriComplete,
            ExpiresIn = authorization.ExpiresIn,
            Interval = authorization.Interval,
        };
        return new DeviceLogin(api, sleep).WaitForTokenAsync(start, ConnectionType, connectionName, cancellation);
    }

    public async Task<AuthInfo> MeAsync(CancellationToken cancellation = default)
    {
        var me = await api.GetAuthAsync(cancellation);
        return new AuthInfo(me.Id, me.Name, me.Email, me.ConnectionId, me.Features);
    }

    public Task LogoutAsync(CancellationToken cancellation = default) => api.LogoutAsync(cancellation);

    public async Task<IReadOnlyList<RemoteRepository>> ListRepositoriesAsync(CancellationToken cancellation = default)
    {
        var list = await api.GetRepositoriesAsync(cancellation);
        return list.Repositories.Select(Repository).ToList();
    }

    public async Task<RemoteRepository> CreateRepositoryAsync(string name, CancellationToken cancellation = default)
    {
        var created = await api.CreateRepositoryAsync(new RepositoryCreateRequestDto { Name = name, Worm = false }, cancellation);
        return Repository(created.Repository);
    }

    public async Task<RemoteRepository> UpdateRepositoryAsync(string repositoryId, string? name = null, bool? worm = null, CancellationToken cancellation = default)
    {
        var updated = await api.UpdateRepositoryAsync(repositoryId, new RepositoryUpdateRequestDto { Name = name, Worm = worm }, cancellation);
        return Repository(updated.Repository);
    }

    public async Task<Uri> CreateTicketAsync(string action, string repositoryId, CancellationToken cancellation = default)
    {
        var ticket = await api.CreateTicketAsync(new TicketCreateRequestDto { Action = action, RepositoryId = Guid.Parse(repositoryId) }, cancellation);
        return WebUrl(ticket.RedirectTo, "ticket redirect");
    }

    public async Task<SupportSession> CreateSupportSessionAsync(string jobId, string jobName, bool includesPaths, string clientVersion, CancellationToken cancellation = default)
    {
        var request = new SupportLogSessionCreateRequestDto { JobId = jobId, JobName = jobName, IncludesPaths = includesPaths, ClientVersion = clientVersion };
        return Session(await api.CreateSupportLogSessionAsync(request, cancellation));
    }

    public async Task<SupportSession> RefreshSupportSessionAsync(string sessionId, CancellationToken cancellation = default) =>
        Session(await api.RefreshSupportLogSessionTokenAsync(sessionId, cancellation));

    public async Task<int> SendSupportBatchAsync(Uri url, string token, byte[] gzippedLines, int sequence, int droppedLines, bool final, CancellationToken cancellation = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = new ByteArrayContent(gzippedLines) };
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/x-ndjson");
        request.Content.Headers.ContentEncoding.Add("gzip");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.Add("x-batch-seq", sequence.ToString(CultureInfo.InvariantCulture));
        request.Headers.Add("x-dropped-lines", droppedLines.ToString(CultureInfo.InvariantCulture));
        if (final)
        {
            request.Headers.Add("x-batch-final", "true");
        }

        using var response = await http.SendAsync(request, cancellation);
        return (int)response.StatusCode;
    }

    public Task DeleteConnectionAsync(string id, CancellationToken cancellation = default) => api.DeleteConnectionAsync(id, cancellation);

    public Task SubmitBackupStartAsync(string repositoryId, CancellationToken cancellation = default) =>
        api.SubmitMetricBackupStartAsync(repositoryId, cancellation);

    public Task SubmitBackupEndAsync(string repositoryId, BackupStatus status, long durationMs, CancellationToken cancellation = default) =>
        api.SubmitMetricBackupEndAsync(repositoryId, new SubmitBackupEndRequestDto { Status = status.ToString().ToLowerInvariant(), DurationMs = durationMs }, cancellation);

    public Task SubmitRepositorySizeAsync(string repositoryId, long sizeBytes, CancellationToken cancellation = default) =>
        api.SubmitMetricRepositorySizeAsync(repositoryId, new SubmitUpdateSizeRequestDto { SizeBytes = sizeBytes }, cancellation);

    public Task SubmitStructuredLogAsync(StructuredLog log, CancellationToken cancellation = default) =>
        api.SubmitStructuredLogAsync(new SubmitStructuredLogRequestDto { Summary = log.Summary, Data = log.Data.ToDictionary(entry => entry.Key, entry => entry.Value!) }, cancellation);

    private static RemoteRepository Repository(RepositoryWithMetricsDto repository) =>
        new(repository.Id, repository.Name, repository.Worm, repository.ConnectionId, repository.ConnectionType, (long?)repository.Metrics?.SizeBytes, repository.Metrics?.LastBackup);

    private static SupportSession Session(SupportLogSessionTokenDto session) =>
        new(session.Id.ToString(), session.Token, session.Url.AbsoluteUri, session.ExpiresAt);

    private static Uri WebUrl(string value, string what)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var url) || (url.Scheme != "https" && url.Scheme != "http"))
        {
            throw new UnexpectedResponseException($"{what} is not a web URL");
        }

        return url;
    }
}
