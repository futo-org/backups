using System.Globalization;

using FutoBackups.Core.Api;
using FutoBackups.Core.State;
using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Tests.Api;

public class YuccaClientTests
{
    private const string RepositoryId = "0b6a1f6e-3c1d-4c2a-9f7e-5d4b3a2c1e0f";
    private static readonly Uri Root = new("https://api.example/api/");

    [Fact]
    public async Task ASignedInClientSendsTheAccessTokenCookieToTheApiRoot()
    {
        var http = new FakeHttp().Respond(200, new { repositories = Array.Empty<object>() });

        await new YuccaClient(Root, http.Client()).WithAccessToken("secret").ListRepositoriesAsync(TestContext.Current.CancellationToken);

        var request = Assert.Single(http.Requests);
        Assert.Equal("yucca-access-token=secret", request.Headers["Cookie"]);
        Assert.Equal("https://api.example/api/repository", request.Url.AbsoluteUri);
    }

    [Fact]
    public async Task DeviceSignInSendsNoCookie()
    {
        var http = new FakeHttp().Respond(201, new { deviceCode = "d", userCode = "ABCD-EFGH", verificationUri = "https://x/", expiresIn = 600 });

        await new YuccaClient(Root, http.Client()).StartDeviceAuthorizationAsync(TestContext.Current.CancellationToken);

        Assert.False(Assert.Single(http.Requests).Headers.ContainsKey("Cookie"));
    }

    [Fact]
    public async Task WaitingForTheTokenSignsInAsAWindowsConnection()
    {
        var http = new FakeHttp().Respond(200, new { status = "SUCCESS", accessToken = "token" });
        var client = new YuccaClient(Root, http.Client(), sleep: (_, _) => Task.CompletedTask);

        var token = await client.WaitForTokenAsync(new DeviceAuthorization("device", "ABCD-EFGH", "https://futo.cloud/device", null, 600, 5), "SAM-DESKTOP", TestContext.Current.CancellationToken);

        Assert.Equal("token", token);
        Assert.Contains("\"connectionType\":\"windows\"", Assert.Single(http.Requests).Body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AnUnauthorizedResponseCarriesItsStatus()
    {
        var error = await Assert.ThrowsAsync<YuccaApiException>(() => new YuccaClient(Root, new FakeHttp().Respond(401).Client()).MeAsync(TestContext.Current.CancellationToken));

        Assert.Equal(401, error.StatusCode);
    }

    [Fact]
    public async Task RepositoriesReadTheirMetrics()
    {
        var http = new FakeHttp().Respond(200, """{"repositories":[{"id":"r1","name":"SAM-DESKTOP","worm":false,"connectionId":"c1","connectionType":"windows","metrics":{"sizeBytes":12,"lastBackup":"2026-11-24T10:00:00Z"}}]}""");

        var repositories = await new YuccaClient(Root, http.Client(), "t").ListRepositoriesAsync(TestContext.Current.CancellationToken);

        Assert.Equal(new RemoteRepository("r1", "SAM-DESKTOP", false, "c1", "windows", 12, DateTimeOffset.Parse("2026-11-24T10:00:00Z", CultureInfo.InvariantCulture)), Assert.Single(repositories));
    }

    [Fact]
    public async Task RenamingARepositoryLeavesWriteOnceUnsent()
    {
        var http = new FakeHttp().Respond(200, """{"repository":{"id":"r1","name":"New","worm":false,"connectionId":"c1","connectionType":"windows","metrics":{"sizeBytes":0}}}""");

        await new YuccaClient(Root, http.Client(), "t").UpdateRepositoryAsync("r1", name: "New", cancellation: TestContext.Current.CancellationToken);

        Assert.Equal("""{"name":"New"}""", Assert.Single(http.Requests).Body);
    }

    [Fact]
    public async Task ABackupEndReportsItsStatusInLowerCase()
    {
        var http = new FakeHttp().Respond(204);

        await new YuccaClient(Root, http.Client(), "t").SubmitBackupEndAsync("r1", BackupStatus.Warn, 1500, TestContext.Current.CancellationToken);

        var request = Assert.Single(http.Requests);
        Assert.Equal("https://api.example/api/metrics/submit/r1/backup/end", request.Url.AbsoluteUri);
        Assert.Equal("""{"status":"warn","durationMs":1500}""", request.Body);
    }

    [Fact]
    public async Task ADeletionTicketMustRedirectToTheWeb() =>
        await Assert.ThrowsAsync<UnexpectedResponseException>(() => new YuccaClient(Root, new FakeHttp().Respond(201, new { redirectTo = "file:///etc/passwd" }).Client(), "t").CreateTicketAsync("repository.delete", RepositoryId, TestContext.Current.CancellationToken));

    [Theory]
    [InlineData("ms-settings:privacy", null)]
    [InlineData("https://futo.cloud/device", "file:///C:/Windows/System32/calc.exe")]
    public async Task DeviceSignInRefusesAVerificationUrlThatIsNotOnTheWeb(string verificationUri, string? verificationUriComplete) =>
        await Assert.ThrowsAsync<UnexpectedResponseException>(() => new YuccaClient(Root, new FakeHttp()
            .Respond(201, new { deviceCode = "d", userCode = "ABCD-EFGH", verificationUri, verificationUriComplete, expiresIn = 600 }).Client())
            .StartDeviceAuthorizationAsync(TestContext.Current.CancellationToken));

    [Fact]
    public async Task SupportBatchesGoToTheStreamerWithTheSessionToken()
    {
        var http = new FakeHttp().Respond(202);

        var status = await new YuccaClient(Root, http.Client(), "t").SendSupportBatchAsync(new Uri("https://logs.example/batch"), "session-token", [1, 2], 3, 4, final: true, TestContext.Current.CancellationToken);

        var request = Assert.Single(http.Requests);
        Assert.Equal(202, status);
        Assert.Equal("Bearer session-token", request.Headers["Authorization"]);
        Assert.Equal("3", request.Headers["x-batch-seq"]);
        Assert.Equal("4", request.Headers["x-dropped-lines"]);
        Assert.Equal("true", request.Headers["x-batch-final"]);
        Assert.False(request.Headers.ContainsKey("Cookie"));
    }
}
