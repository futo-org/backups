using System.Net;
using System.Text.Json;

namespace FutoBackups.YuccaApi;

public sealed record ServerInfo(Uri ApiRoot, int ResticPackSizeMiB = 16, string ConnectionsMath = "16");

public sealed class Discovery(HttpClient http, IReadOnlyList<TimeSpan>? retryDelays = null, Func<TimeSpan, CancellationToken, Task>? sleep = null)
{
    public static readonly TimeSpan[] DefaultRetryDelays = [TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(3)];

    private static readonly string[] LoopbackHosts = ["localhost", "127.0.0.1", "::1", "[::1]"];

    private readonly IReadOnlyList<TimeSpan> retryDelays = retryDelays ?? DefaultRetryDelays;
    private readonly Func<TimeSpan, CancellationToken, Task> sleep = sleep ?? Task.Delay;

    public async Task<ServerInfo> ResolveAsync(Uri url, CancellationToken cancellation = default)
    {
        RequireSecureTransport(url, "server URL");
        var document = await FetchDocumentAsync(url, cancellation);
        if (document.TryGetProperty("api_root", out var root) && root.ValueKind == JsonValueKind.String) return ServerInfoFrom(document);
        if (document.TryGetProperty("meta_url", out var meta) && meta.ValueKind == JsonValueKind.String && Uri.TryCreate(meta.GetString(), UriKind.Absolute, out var metaUrl))
        {
            RequireSecureTransport(metaUrl, "meta_url");
            var metaDocument = await FetchDocumentAsync(metaUrl, cancellation);
            if (metaDocument.TryGetProperty("api_root", out var metaRoot) && metaRoot.ValueKind == JsonValueKind.String) return ServerInfoFrom(metaDocument);
            throw new DiscoveryException(DiscoveryProblem.NotAServer, $"meta document at {metaUrl} has no api_root");
        }

        throw new DiscoveryException(DiscoveryProblem.NotAServer, $"document at {url} has neither api_root nor meta_url");
    }

    public static void RequireSecureTransport(Uri url, string name)
    {
        switch (url.Scheme.ToLowerInvariant())
        {
            case "https":
                return;
            case "http" when LoopbackHosts.Contains(url.Host.ToLowerInvariant()):
                return;
            case "http":
                throw new DiscoveryException(DiscoveryProblem.Insecure, $"{name} {url} must use https");
            default:
                throw new DiscoveryException(DiscoveryProblem.NotAServer, $"{name} {url} is not a valid http(s) URL");
        }
    }

    private static bool IsTransient(Exception error) => error is HttpRequestException { HttpRequestError: HttpRequestError.ConnectionError or HttpRequestError.NameResolutionError }
        or TaskCanceledException { InnerException: TimeoutException };

    private async Task<JsonElement> FetchDocumentAsync(Uri url, CancellationToken cancellation)
    {
        using var response = await SendRetryingTransientFailuresAsync(url, cancellation);
        if (response.StatusCode == HttpStatusCode.NotFound) throw new DiscoveryException(DiscoveryProblem.NotAServer, $"no discovery document at {url}");
        var body = await response.Content.ReadAsStringAsync(cancellation);
        if (!response.IsSuccessStatusCode)
        {
            throw new YuccaApiException("The discovery document could not be fetched.", (int)response.StatusCode, body, new Dictionary<string, IEnumerable<string>>(), null);
        }

        try
        {
            var document = JsonSerializer.Deserialize<JsonElement>(body);
            if (document.ValueKind != JsonValueKind.Object) throw new UnexpectedResponseException("discovery document is not an object");
            return document;
        }
        catch (JsonException error)
        {
            throw new UnexpectedResponseException(error.Message);
        }
    }

    private async Task<HttpResponseMessage> SendRetryingTransientFailuresAsync(Uri url, CancellationToken cancellation)
    {
        foreach (var delay in retryDelays)
        {
            try
            {
                return await http.GetAsync(url, cancellation);
            }
            catch (Exception error) when (IsTransient(error) && !cancellation.IsCancellationRequested)
            {
                await sleep(delay, cancellation);
            }
        }

        return await http.GetAsync(url, cancellation);
    }

    private static ServerInfo ServerInfoFrom(JsonElement document)
    {
        if (!Uri.TryCreate(document.GetProperty("api_root").GetString(), UriKind.Absolute, out var apiRoot))
        {
            throw new DiscoveryException(DiscoveryProblem.NotAServer, "meta document api_root is not a valid http(s) URL");
        }

        RequireSecureTransport(apiRoot, "api_root");
        var server = new ServerInfo(apiRoot);
        if (document.TryGetProperty("config", out var config) && config.ValueKind == JsonValueKind.Object)
        {
            if (config.TryGetProperty("restic_pack_size_mib", out var pack) && pack.ValueKind == JsonValueKind.Number && pack.TryGetInt32(out var packSize) && packSize >= 1)
            {
                server = server with { ResticPackSizeMiB = packSize };
            }

            if (config.TryGetProperty("connections_math", out var math) && math.ValueKind == JsonValueKind.String)
            {
                server = server with { ConnectionsMath = math.GetString()! };
            }
        }

        return server;
    }
}
