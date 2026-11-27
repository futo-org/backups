using FutoBackups.YuccaApi;

namespace FutoBackups.Core.Tests.YuccaApi;

public class DeviceLoginTests
{
    private static DeviceFlowStartDto Authorization(long expiresIn = 600, long? interval = null) =>
        new() { DeviceCode = "device", UserCode = "ABCD-EFGH", VerificationUri = "https://futo.cloud/device", ExpiresIn = expiresIn, Interval = interval };

    private static (DeviceLogin Login, List<TimeSpan> Sleeps) Login(FakeHttp http)
    {
        var sleeps = new List<TimeSpan>();
        return (new DeviceLogin(new YuccaApiClient(http.Client(), new Uri("https://api.example/api/")), (delay, _) =>
        {
            sleeps.Add(delay);
            return Task.CompletedTask;
        }), sleeps);
    }

    [Fact]
    public async Task SucceedsAfterPendingPolls()
    {
        var (login, sleeps) = Login(new FakeHttp().Respond(200, new { status = "PENDING" }).Respond(200, new { status = "PENDING" }).Respond(200, new { status = "SUCCESS", accessToken = "token" }));

        Assert.Equal("token", await login.WaitForTokenAsync(Authorization(interval: 3), "windows", "PC", TestContext.Current.CancellationToken));
        Assert.Equal([TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(3), TimeSpan.FromSeconds(3)], sleeps);
    }

    [Fact]
    public async Task EveryPollSendsTheDeviceCodeAndConnection()
    {
        var http = new FakeHttp().Respond(200, new { status = "SUCCESS", accessToken = "token" });

        await Login(http).Login.WaitForTokenAsync(Authorization(), "windows", "SAM-DESKTOP", TestContext.Current.CancellationToken);

        var request = Assert.Single(http.Requests);
        Assert.Equal("https://api.example/api/auth/oidc/device/token", request.Url.AbsoluteUri);
        Assert.Contains("\"deviceCode\":\"device\"", request.Body, StringComparison.Ordinal);
        Assert.Contains("\"connectionType\":\"windows\"", request.Body, StringComparison.Ordinal);
        Assert.Contains("\"connectionName\":\"SAM-DESKTOP\"", request.Body, StringComparison.Ordinal);
    }

    [Fact]
    public async Task PollsEveryFiveSecondsWhenTheServerGivesNoInterval()
    {
        var (login, sleeps) = Login(new FakeHttp().Respond(200, new { status = "SUCCESS", accessToken = "token" }));

        await login.WaitForTokenAsync(Authorization(), "windows", "PC", TestContext.Current.CancellationToken);

        Assert.Equal([TimeSpan.FromSeconds(5)], sleeps);
    }

    [Fact]
    public async Task SlowDownAddsFiveSecondsToEveryLaterPoll()
    {
        var (login, sleeps) = Login(new FakeHttp().Respond(200, new { status = "SLOW_DOWN" }).Respond(200, new { status = "SLOW_DOWN" }).Respond(200, new { status = "SUCCESS", accessToken = "t" }));

        await login.WaitForTokenAsync(Authorization(interval: 5), "windows", "PC", TestContext.Current.CancellationToken);

        Assert.Equal([TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(15)], sleeps);
    }

    [Fact]
    public async Task PollingStopsWhenTheCodeExpires()
    {
        var http = new FakeHttp().Respond(200, new { status = "PENDING" }).Respond(200, new { status = "PENDING" });

        var error = await Assert.ThrowsAsync<DeviceLoginException>(() => Login(http).Login.WaitForTokenAsync(Authorization(expiresIn: 10, interval: 5), "windows", "PC", TestContext.Current.CancellationToken));

        Assert.Equal(DeviceLoginException.Expired, error.Reason);
        Assert.Equal(2, http.Requests.Count);
    }

    [Theory]
    [InlineData("ACCESS_DENIED")]
    [InlineData("SOMETHING_NEW")]
    public async Task AFailureReportsTheServersReasonEvenAnUnknownOne(string reason)
    {
        var (login, _) = Login(new FakeHttp().Respond(200, new { status = "FAILURE", reason }));

        var error = await Assert.ThrowsAsync<DeviceLoginException>(() => login.WaitForTokenAsync(Authorization(), "windows", "PC", TestContext.Current.CancellationToken));

        Assert.Equal(reason, error.Reason);
    }

    [Fact]
    public async Task ASuccessWithoutATokenIsAnUnexpectedResponse()
    {
        var (login, _) = Login(new FakeHttp().Respond(200, new { status = "SUCCESS" }));

        await Assert.ThrowsAsync<UnexpectedResponseException>(() => login.WaitForTokenAsync(Authorization(), "windows", "PC", TestContext.Current.CancellationToken));
    }
}
