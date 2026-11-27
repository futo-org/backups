using System.Net;
using System.Text;
using System.Text.Json;

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
