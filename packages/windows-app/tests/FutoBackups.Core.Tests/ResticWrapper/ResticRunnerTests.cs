using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.ResticWrapper;

public sealed class ResticRunnerTests
{
    private static readonly ResticRunner Shell = new(Path.Combine(Environment.SystemDirectory, "cmd.exe"));

    private static ResticInvocation Command(string command, IReadOnlyDictionary<string, string>? environment = null) =>
        new(["/d", "/c", command], environment ?? new Dictionary<string, string>());

    [Fact]
    public async Task OnlyAllowedVariablesAndTheInvocationsOwnReachTheProcess()
    {
        Environment.SetEnvironmentVariable("FUTO_TEST_LEAK", "leaked");
        try
        {
            var result = await Shell.RunAsync(Command("set", new Dictionary<string, string> { ["RESTIC_PASSWORD"] = "secret" }), cancellation: TestContext.Current.CancellationToken);

            Assert.Contains("RESTIC_PASSWORD=secret", result.Stdout, StringComparison.Ordinal);
            Assert.Contains("SystemRoot=", result.Stdout, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("FUTO_TEST_LEAK", result.Stdout, StringComparison.Ordinal);
        }
        finally
        {
            Environment.SetEnvironmentVariable("FUTO_TEST_LEAK", null);
        }
    }

    [Fact]
    public async Task AFailingExitCodeIsReturnedWithStderrRatherThanThrown()
    {
        var result = await Shell.RunAsync(Command("echo broken 1>&2 & exit 3"), cancellation: TestContext.Current.CancellationToken);

        Assert.Equal(3, result.ExitCode);
        Assert.Contains("broken", result.Stderr, StringComparison.Ordinal);
    }

    [Fact]
    public async Task DiscardedOutputStillStreamsEveryLine()
    {
        var lines = new List<string>();

        var result = await Shell.RunAsync(Command("echo one & echo two") with { RetainsStdout = false }, lines.Add, TestContext.Current.CancellationToken);

        Assert.Empty(result.Stdout);
        Assert.Equal(["one ", "two"], lines);
    }

    [Fact]
    public async Task CancellingARunningCommandStopsItAndThrows()
    {
        using var cancellation = new CancellationTokenSource();

        var run = Shell.RunAsync(Command("echo started & ping -n 60 127.0.0.1 > nul"), line => cancellation.Cancel(), cancellation.Token);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
    }

    [Fact]
    public async Task ACommandCancelledBeforeItStartsNeverRuns()
    {
        var marker = Path.Combine(Path.GetTempPath(), $"futo-runner-{Guid.NewGuid():N}");
        using var cancellation = new CancellationTokenSource();
        await cancellation.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Shell.RunAsync(Command($"type nul > \"{marker}\""), cancellation: cancellation.Token));
        Assert.False(File.Exists(marker));
    }
}
