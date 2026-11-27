using FutoBackups.Core.Restic;
using FutoBackups.Core.Support;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.Support;

public class RecordingResticTests
{
    private sealed class Sink : ISupportLogSink
    {
        public List<(string Channel, string Command, string Message)> Lines { get; } = [];

        public void Add(string channel, string command, string message) => Lines.Add((channel, command, message));
    }

    private sealed class Runner : IResticExecuting
    {
        public ResticInvocation? Ran { get; private set; }

        public Task<ResticResult> RunAsync(ResticInvocation invocation, Action<string>? onLine = null, CancellationToken cancellation = default)
        {
            Ran = invocation;
            onLine?.Invoke("""{"message_type":"status"}""");
            return Task.FromResult(new ResticResult(1, string.Empty, "Fatal: repository is locked\n"));
        }
    }

    [Fact]
    public async Task ARecordedCommandRunsVerboselyAndKeepsEveryLine()
    {
        var sink = new Sink();
        var runner = new Runner();
        var forwarded = new List<string>();

        await new RecordingRestic(runner, sink).RunAsync(new ResticInvocation(["backup", "--json", "--", @"C:\Data"], new Dictionary<string, string>()), forwarded.Add, TestContext.Current.CancellationToken);

        Assert.Equal<string>(["backup", "--verbose=2", "--json", "--", @"C:\Data"], runner.Ran!.Arguments);
        Assert.Single(forwarded);
        Assert.Contains(("stderr", "backup", "Fatal: repository is locked"), sink.Lines);
        Assert.Equal(("meta", "backup", "exited with code 1"), sink.Lines[^1]);
    }
}
