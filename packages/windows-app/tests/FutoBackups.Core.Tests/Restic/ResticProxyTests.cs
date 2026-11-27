using System.Net.Sockets;
using System.Runtime.InteropServices;

using FutoBackups.Core.Restic;
using FutoBackups.Core.State;

namespace FutoBackups.Core.Tests.Restic;

public sealed class ResticProxyTests
{
    private static readonly Uri ApiRoot = new("http://127.0.0.1:9/api/");

    private static string Proxy()
    {
        var arch = RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        var executable = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "..", "build", "helpers", arch, "restic-proxy.exe"));
        Assert.SkipUnless(File.Exists(executable), "Build the test project to build restic-proxy first.");
        return executable;
    }

    [Fact]
    public async Task AStartedProxyListensOnALoopbackPort()
    {
        await using var handle = await new ResticProxyLauncher(Proxy()).StartAsync(ApiRoot, Throttle.Unthrottled, TestContext.Current.CancellationToken);
        var (host, port) = (handle.Address.Split(':')[0], int.Parse(handle.Address.Split(':')[1], System.Globalization.CultureInfo.InvariantCulture));
        using var client = new TcpClient();

        await client.ConnectAsync(host, port, TestContext.Current.CancellationToken);

        Assert.Equal("127.0.0.1", host);
        Assert.True(client.Connected);
    }

    [Fact]
    public async Task ThrottleAndNetworkChangesReachARunningProxy()
    {
        await using var handle = await new ResticProxyLauncher(Proxy()).StartAsync(ApiRoot, Throttle.Unthrottled, TestContext.Current.CancellationToken);

        await handle.SetThrottleAsync(new Throttle(2048, "22:00-06:00"));
        await handle.NetworkChangedAsync();

        Assert.Equal(0, handle.UploadedBytes);
    }

    [Fact]
    public async Task AHelperThatExitsBeforeItIsReadyFailsToStart()
    {
        var launcher = new ResticProxyLauncher(Path.Combine(Environment.SystemDirectory, "cmd.exe"), readyTimeout: TimeSpan.FromSeconds(5));

        var error = await Assert.ThrowsAsync<ResticProxyException>(() => launcher.StartAsync(ApiRoot, Throttle.Unthrottled, TestContext.Current.CancellationToken));

        Assert.Equal("timeout or exited before ready", error.Reason);
    }

    [Fact]
    public async Task AMissingHelperFailsToStart()
    {
        var launcher = new ResticProxyLauncher(Path.Combine(Path.GetTempPath(), $"missing-{Guid.NewGuid():N}.exe"));

        await Assert.ThrowsAsync<ResticProxyException>(() => launcher.StartAsync(ApiRoot, Throttle.Unthrottled, TestContext.Current.CancellationToken));
    }

    [Fact]
    public void TheRepositoryUrlCarriesTheTokenToTheProxy() =>
        Assert.Equal("rest:http://repo-1:token-abc@127.0.0.1:5000", ResticProxyUrls.Repository("127.0.0.1:5000", "repo-1", "token-abc"));

    [Theory]
    [InlineData("""{"type":"progress","uploadedBytes":4096}""", 4096L)]
    [InlineData("""{"type":"ready","address":"127.0.0.1:5000"}""", null)]
    [InlineData("""{"type":"progress"}""", null)]
    [InlineData("not json", null)]
    public void OnlyProgressMessagesReportUploadedBytes(string line, long? expected) =>
        Assert.Equal(expected, ProxyMessages.UploadedBytes(line));
}
