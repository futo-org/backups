using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;

using FutoBackups.Core.Api;
using FutoBackups.Core.Engine;
using FutoBackups.Core.Restic;
using FutoBackups.Core.State;
using FutoBackups.ResticWrapper;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Tests;

public sealed record RecordedRequest(HttpMethod Method, Uri Url, IReadOnlyDictionary<string, string> Headers, string? Body);

public sealed class FakeHttp : HttpMessageHandler
{
    private readonly Queue<Func<HttpResponseMessage>> responses = new();

    public List<RecordedRequest> Requests { get; } = [];

    public HttpClient Client() => new(this, disposeHandler: false);

    public FakeHttp Respond(int status, object? body = null)
    {
        var text = body is null ? string.Empty : body as string ?? JsonSerializer.Serialize(body);
        responses.Enqueue(() => new HttpResponseMessage((HttpStatusCode)status) { Content = new StringContent(text, Encoding.UTF8, "application/json") });
        return this;
    }

    public FakeHttp Throw(Exception error)
    {
        responses.Enqueue(() => throw error);
        return this;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var headers = request.Headers.Concat(request.Content?.Headers.AsEnumerable() ?? []).ToDictionary(header => header.Key, header => string.Join(", ", header.Value), StringComparer.OrdinalIgnoreCase);
        var body = request.Content is null ? null : await request.Content.ReadAsStringAsync(cancellationToken);
        Requests.Add(new RecordedRequest(request.Method, request.RequestUri!, headers, body));
        return responses.Dequeue()();
    }
}

public sealed class FakeRestic : IResticExecuting
{
    public List<ResticInvocation> Invocations { get; } = [];

    public Func<ResticInvocation, Action<string>?, CancellationToken, Task<ResticResult>> Handler { get; set; } =
        (_, _, _) => Task.FromResult(new ResticResult(0, string.Empty, string.Empty));

    public async Task<ResticResult> RunAsync(ResticInvocation invocation, Action<string>? onLine = null, CancellationToken cancellation = default)
    {
        Invocations.Add(invocation);
        cancellation.ThrowIfCancellationRequested();
        return await Handler(invocation, onLine, cancellation);
    }

    public IEnumerable<string> Commands => Invocations.Select(invocation => invocation.Arguments[0]);
}

public sealed class FakeProxy : IResticProxyLaunching, IResticProxyHandle
{
    public int Started { get; private set; }

    public int Stopped { get; private set; }

    public string Address => "127.0.0.1:50000";

    public long UploadedBytes { get; set; }

    public Task<IResticProxyHandle> StartAsync(Uri apiRoot, Throttle throttle, CancellationToken cancellation = default)
    {
        Started++;
        return Task.FromResult<IResticProxyHandle>(this);
    }

    public List<Throttle> Throttles { get; } = [];

    public Task SetThrottleAsync(Throttle throttle)
    {
        Throttles.Add(throttle);
        return Task.CompletedTask;
    }

    public Task NetworkChangedAsync() => Task.CompletedTask;

    public ValueTask DisposeAsync()
    {
        Stopped++;
        return ValueTask.CompletedTask;
    }
}

public sealed class FakeApi : IYuccaRepositoryApi
{
    public List<string> Calls { get; } = [];

    public List<RemoteRepository> Repositories { get; } = [];

    public List<StructuredLog> Logs { get; } = [];

    public Task<IReadOnlyList<RemoteRepository>> ListRepositoriesAsync(CancellationToken cancellation = default) => Task.FromResult<IReadOnlyList<RemoteRepository>>(Repositories);

    public Task<RemoteRepository> CreateRepositoryAsync(string name, CancellationToken cancellation = default)
    {
        Calls.Add($"create {name}");
        return Task.FromResult(new RemoteRepository("repo-1", name, false, ConnectionType: "windows"));
    }

    public Task SubmitBackupStartAsync(string repositoryId, CancellationToken cancellation = default)
    {
        Calls.Add("start");
        return Task.CompletedTask;
    }

    public Task SubmitBackupEndAsync(string repositoryId, BackupStatus status, long durationMs, CancellationToken cancellation = default)
    {
        Calls.Add($"end {status}");
        return Task.CompletedTask;
    }

    public Task SubmitRepositorySizeAsync(string repositoryId, long sizeBytes, CancellationToken cancellation = default)
    {
        Calls.Add($"size {sizeBytes}");
        return Task.CompletedTask;
    }

    public Task SubmitStructuredLogAsync(StructuredLog log, CancellationToken cancellation = default)
    {
        Logs.Add(log);
        return Task.CompletedTask;
    }
}

public sealed class EngineFixture
{
    public const string MasterKey = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    public FakeRestic Restic { get; } = new();

    public FakeProxy Proxy { get; } = new();

    public FakeApi Api { get; } = new();

    public InMemorySecretStore Secrets { get; } = new(new() { [SecretKey.AccessToken] = "token", [SecretKey.MasterKey] = MasterKey });

    public BackupEngine Engine { get; }

    public EngineFixture(string? temporaryDirectory = null)
    {
        Engine = new BackupEngine(new EngineEnvironment(
            Secrets,
            (_, _) => Task.FromResult(new ServerInfo(new Uri("https://api.example/"), 16, "8")),
            (_, _) => Api,
            Restic,
            Proxy,
            Path.GetTempPath(),
            4,
            () => DateTimeOffset.Parse("2026-11-25T12:00:00Z", CultureInfo.InvariantCulture))
        {
            WatchNetworkChanges = _ => new NoWatch(),
            UploadTickInterval = TimeSpan.FromMilliseconds(10),
        })
        {
            TemporaryDirectory = temporaryDirectory ?? Path.GetTempPath(),
        };
    }

    public static AppConfig Config => AppConfig.Defaults("test-pc", @"C:\Users\test") with
    {
        RepositoryId = "repo-1",
        Folders = [@"C:\Users\test\Documents"],
        TelemetryConsentedAt = DateTimeOffset.Parse("2026-11-01T00:00:00Z", CultureInfo.InvariantCulture),
    };

    private sealed class NoWatch : IDisposable
    {
        public void Dispose()
        {
        }
    }
}
