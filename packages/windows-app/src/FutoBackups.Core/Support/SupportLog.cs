using System.IO.Compression;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

using FutoBackups.Core.Api;
using FutoBackups.Core.Restic;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Support;

public interface ISupportLogSink
{
    void Add(string channel, string command, string message);
}

public sealed class SupportLog(string path, PathRedactor? redactor, SupportLogUploader? stream, Func<DateTimeOffset> now) : ISupportLogSink, IAsyncDisposable
{
    private static readonly JsonSerializerOptions LineOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private readonly Lock gate = new();
    private readonly StreamWriter file = OpenFile(path);
    private bool finished;

    public string Path => path;

    public string? Code => stream?.SessionId;

    public void Add(string channel, string command, string message)
    {
        var line = JsonSerializer.Serialize(new { time = now().ToString("O"), stream = channel, command, message = redactor?.Redact(message) ?? message }, LineOptions);
        lock (gate)
        {
            file.WriteLine(line);
        }

        stream?.Add(line);
    }

    public async ValueTask DisposeAsync()
    {
        if (finished) return;
        finished = true;
        await file.DisposeAsync();
        if (stream is not null)
        {
            await stream.FinishAsync();
            stream.Dispose();
        }
    }

    private static StreamWriter OpenFile(string path)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        return new StreamWriter(path, false, new UTF8Encoding(false));
    }
}

public sealed class SupportLogUploader(IAccountApi api, SupportSession session) : IDisposable
{
    private const int BatchBytes = 1024 * 1024;
    private const int MaxBufferedBytes = 32 * 1024 * 1024;

    private readonly Lock gate = new();
    private readonly SemaphoreSlim sending = new(1, 1);
    private readonly List<Task> inFlight = [];
    private List<string> batch = [];
    private int batchBytes;
    private int bufferedBytes;
    private int sequence;
    private int dropped;
    private SupportSession current = session;

    public string SessionId => current.Id;

    public void Add(string line)
    {
        List<string>? full = null;
        lock (gate)
        {
            if (bufferedBytes + line.Length > MaxBufferedBytes)
            {
                dropped++;
                return;
            }

            batch.Add(line);
            batchBytes += line.Length;
            bufferedBytes += line.Length;
            if (batchBytes >= BatchBytes)
            {
                full = batch;
                batch = [];
                batchBytes = 0;
            }
        }

        if (full is not null)
        {
            lock (gate)
            {
                inFlight.Add(SendAsync(full, false));
            }
        }
    }

    public async Task FinishAsync()
    {
        List<string> last;
        Task[] pending;
        lock (gate)
        {
            last = batch;
            batch = [];
            pending = [.. inFlight];
        }

        await Task.WhenAll(pending);
        await SendAsync(last, true);
    }

    public void Dispose() => sending.Dispose();

    private async Task SendAsync(List<string> lines, bool final)
    {
        await sending.WaitAsync();
        try
        {
            var body = Compress(lines);
            int droppedNow;
            int sequenceNow;
            lock (gate)
            {
                droppedNow = dropped;
                dropped = 0;
                sequenceNow = sequence++;
            }

            for (var attempt = 0; attempt < 3; attempt++)
            {
                try
                {
                    var status = await api.SendSupportBatchAsync(new Uri(current.Url), current.Token, body, sequenceNow, droppedNow, final);
                    if (status is >= 200 and < 300) break;
                    if (status == 401)
                    {
                        current = await api.RefreshSupportSessionAsync(current.Id);
                        continue;
                    }

                    if (status is >= 400 and < 500) break;
                }
                catch (Exception)
                {
                }
            }
        }
        finally
        {
            lock (gate)
            {
                bufferedBytes -= lines.Sum(line => line.Length);
            }

            sending.Release();
        }
    }

    private static byte[] Compress(List<string> lines)
    {
        using var output = new MemoryStream();
        using (var gzip = new GZipStream(output, CompressionLevel.Fastest))
        {
            var text = lines.Count > 0 ? string.Join('\n', lines) + "\n" : string.Empty;
            gzip.Write(Encoding.UTF8.GetBytes(text));
        }

        return output.ToArray();
    }
}

public sealed class RecordingRestic(IResticExecuting inner, ISupportLogSink sink) : IResticExecuting
{
    public const string Verbose = "--verbose=2";

    public async Task<ResticResult> RunAsync(ResticInvocation invocation, Action<string>? onLine = null, CancellationToken cancellation = default)
    {
        var command = invocation.Arguments.Count > 0 ? invocation.Arguments[0] : "restic";
        var verbose = invocation with { Arguments = [.. invocation.Arguments.Take(1), Verbose, .. invocation.Arguments.Skip(1)] };
        sink.Add("meta", command, "started");
        var result = await inner.RunAsync(verbose, line =>
        {
            sink.Add("stdout", command, line);
            onLine?.Invoke(line);
        }, cancellation);
        foreach (var line in result.Stderr.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            sink.Add("stderr", command, line);
        }

        sink.Add("meta", command, $"exited with code {result.ExitCode}");
        return result;
    }
}
