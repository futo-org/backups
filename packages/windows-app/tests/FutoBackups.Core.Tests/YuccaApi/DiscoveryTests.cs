using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Tests.YuccaApi;

public class DiscoveryTests
{
    private static readonly Uri WellKnown = new("https://meta.futo.cloud/.well-known/yucca.json");

    private static Discovery Discovery(FakeHttp http) => new(http.Client(), [TimeSpan.Zero, TimeSpan.Zero], (_, _) => Task.CompletedTask);

    [Fact]
    public async Task AWellKnownDocumentResolvesThroughTheMetaDocument()
    {
        var http = new FakeHttp()
            .Respond(200, new { meta_url = "https://meta.futo.cloud/api/meta" })
            .Respond(200, new { api_root = "https://api.futo.cloud/api", config = new { restic_pack_size_mib = 32, connections_math = "12" } });

        var server = await Discovery(http).ResolveAsync(WellKnown, TestContext.Current.CancellationToken);

        Assert.Equal(new ServerInfo(new Uri("https://api.futo.cloud/api"), 32, "12"), server);
        Assert.Equal(2, http.Requests.Count);
    }

    [Fact]
    public async Task AMetaDocumentWithoutConfigUsesTheDefaults() =>
        Assert.Equal(new ServerInfo(new Uri("https://api.example/api"), 16, "16"), await Discovery(new FakeHttp().Respond(200, new { api_root = "https://api.example/api" })).ResolveAsync(WellKnown, TestContext.Current.CancellationToken));

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    public async Task APackSizeBelowOneFallsBackToTheDefault(int packSize)
    {
        var server = await Discovery(new FakeHttp().Respond(200, new { api_root = "https://api.example/api", config = new { restic_pack_size_mib = packSize } })).ResolveAsync(WellKnown, TestContext.Current.CancellationToken);

        Assert.Equal(16, server.ResticPackSizeMiB);
    }

    [Theory]
    [InlineData("http://example.com/.well-known/yucca.json")]
    [InlineData("http://192.168.1.10/.well-known/yucca.json")]
    public async Task ANonLoopbackPlainHttpServerIsRejectedBeforeAnyRequest(string url)
    {
        var http = new FakeHttp();

        var error = await Assert.ThrowsAsync<DiscoveryException>(() => Discovery(http).ResolveAsync(new Uri(url), TestContext.Current.CancellationToken));

        Assert.Equal(DiscoveryProblem.Insecure, error.Problem);
        Assert.Empty(http.Requests);
    }

    [Theory]
    [InlineData("http://localhost:3020/api/meta")]
    [InlineData("http://127.0.0.1:3020/api/meta")]
    public async Task ALoopbackPlainHttpServerIsAllowed(string url)
    {
        var server = await Discovery(new FakeHttp().Respond(200, new { api_root = "http://localhost:3020/api" })).ResolveAsync(new Uri(url), TestContext.Current.CancellationToken);

        Assert.Equal("http", server.ApiRoot.Scheme);
    }

    [Fact]
    public async Task APlainHttpMetaUrlIsRejectedBeforeFollowingIt()
    {
        var http = new FakeHttp().Respond(200, new { meta_url = "http://evil.example/meta" });

        var error = await Assert.ThrowsAsync<DiscoveryException>(() => Discovery(http).ResolveAsync(WellKnown, TestContext.Current.CancellationToken));

        Assert.Equal(DiscoveryProblem.Insecure, error.Problem);
        Assert.Single(http.Requests);
    }

    [Fact]
    public async Task APlainHttpApiRootIsRejected()
    {
        var error = await Assert.ThrowsAsync<DiscoveryException>(() => Discovery(new FakeHttp().Respond(200, new { api_root = "http://api.example/api" })).ResolveAsync(WellKnown, TestContext.Current.CancellationToken));

        Assert.Equal(DiscoveryProblem.Insecure, error.Problem);
    }

    [Fact]
    public async Task AMissingDiscoveryDocumentIsNotAServer()
    {
        var error = await Assert.ThrowsAsync<DiscoveryException>(() => Discovery(new FakeHttp().Respond(404)).ResolveAsync(WellKnown, TestContext.Current.CancellationToken));

        Assert.Equal(DiscoveryProblem.NotAServer, error.Problem);
    }

    [Fact]
    public async Task ADocumentWithNeitherApiRootNorMetaUrlIsNotAServer()
    {
        var error = await Assert.ThrowsAsync<DiscoveryException>(() => Discovery(new FakeHttp().Respond(200, new { other = 1 })).ResolveAsync(WellKnown, TestContext.Current.CancellationToken));

        Assert.Equal(DiscoveryProblem.NotAServer, error.Problem);
    }

    [Fact]
    public async Task MalformedJsonIsAnUnexpectedResponse() =>
        await Assert.ThrowsAsync<UnexpectedResponseException>(() => Discovery(new FakeHttp().Respond(200, "{not json")).ResolveAsync(WellKnown, TestContext.Current.CancellationToken));

    [Fact]
    public async Task AServerErrorCarriesItsStatusAndIsNotRetried()
    {
        var http = new FakeHttp().Respond(503);

        var error = await Assert.ThrowsAsync<YuccaApiException>(() => Discovery(http).ResolveAsync(WellKnown, TestContext.Current.CancellationToken));

        Assert.Equal(503, error.StatusCode);
        Assert.Single(http.Requests);
    }

    [Fact]
    public async Task AnUnreachableServerIsRetriedTwiceBeforeFailing()
    {
        var http = new FakeHttp()
            .Throw(new HttpRequestException(HttpRequestError.ConnectionError))
            .Throw(new HttpRequestException(HttpRequestError.ConnectionError))
            .Respond(200, new { api_root = "https://api.example/api" });

        await Discovery(http).ResolveAsync(WellKnown, TestContext.Current.CancellationToken);

        Assert.Equal(3, http.Requests.Count);
    }
}
