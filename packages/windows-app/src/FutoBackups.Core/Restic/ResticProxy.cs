using System.Diagnostics;
using System.Globalization;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

using FutoBackups.Core.State;
using FutoBackups.Core.Strings;

namespace FutoBackups.Core.Restic;

public interface IResticProxyHandle : IAsyncDisposable
{
    string Address { get; }

    long UploadedBytes { get; }

    Task SetThrottleAsync(Throttle throttle);

    Task NetworkChangedAsync();
}

public interface IResticProxyLaunching
{
    Task<IResticProxyHandle> StartAsync(Uri apiRoot, Throttle throttle, CancellationToken cancellation = default);
}

public sealed class ResticProxyException(string reason) : Exception(Text.ErrorHelperCouldNotStart)
{
    public string Reason { get; } = reason;
}

public static class ResticProxyUrls
{
    public static string Repository(string address, string repositoryId, string accessToken) => $"rest:http://{repositoryId}:{accessToken}@{address}";
}

public sealed class ResticProxyLauncher(string executable, TimeSpan? readyTimeout = null, TimeSpan? progressInterval = null) : IResticProxyLaunching
{
    private readonly TimeSpan readyTimeout = readyTimeout ?? TimeSpan.FromSeconds(10);
    private readonly TimeSpan progressInterval = progressInterval ?? TimeSpan.FromMilliseconds(500);

    public async Task<IResticProxyHandle> StartAsync(Uri apiRoot, Throttle throttle, CancellationToken cancellation = default)
    {
        var pipeName = $"futo-backups-proxy-{Environment.ProcessId}-{Guid.NewGuid():N}";
        var server = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        var connecting = server.WaitForConnectionAsync(cancellation);
        var child = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous, System.Security.Principal.TokenImpersonationLevel.Anonymous, HandleInheritability.Inheritable);
        child.Connect(5000);
        await connecting;

        var start = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        start.Environment.Clear();
        foreach (var name in new[] { "SystemRoot", "SystemDrive", "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA", "PATH", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY" })
        {
            if (Environment.GetEnvironmentVariable(name) is { } value)
            {
                start.Environment[name] = value;
            }
        }

        start.Environment["RESTIC_PROXY_API_URL"] = apiRoot.AbsoluteUri.TrimEnd('/');
        start.Environment["RESTIC_PROXY_HOST"] = "127.0.0.1";
        start.Environment["RESTIC_PROXY_PORT"] = "0";
        start.Environment["RESTIC_PROXY_READY_FD"] = child.SafePipeHandle.DangerousGetHandle().ToInt64().ToString(CultureInfo.InvariantCulture);
        start.Environment["RESTIC_PROXY_PROGRESS_INTERVAL_MS"] = ((int)progressInterval.TotalMilliseconds).ToString(CultureInfo.InvariantCulture);
        start.Environment["RESTIC_PROXY_THROTTLE_BYTES_PER_SEC"] = throttle.BytesPerSec.ToString(CultureInfo.InvariantCulture);
        start.Environment["RESTIC_PROXY_THROTTLE_QUIET_HOURS"] = throttle.QuietHours;
        start.Environment["LOG_FORMAT"] = "json";
        start.Environment["LOG_LEVEL"] = "info";

        Process process;
        try
        {
            process = Process.Start(start) ?? throw new ResticProxyException("spawn failed");
        }
        catch (Exception error) when (error is not ResticProxyException)
        {
            await child.DisposeAsync();
            await server.DisposeAsync();
            throw new ResticProxyException(error.Message);
        }

        await child.DisposeAsync();
        process.StandardInput.Close();
        _ = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        _ = process.StandardError.ReadToEndAsync(CancellationToken.None);

        var reader = new StreamReader(server, Encoding.UTF8, false, 4096, true);
        string? line;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            timeout.CancelAfter(readyTimeout);
            line = await reader.ReadLineAsync(timeout.Token);
        }
        catch (OperationCanceledException) when (!cancellation.IsCancellationRequested)
        {
            line = null;
        }

        var address = line is null ? null : TryReadAddress(line);
        if (address is null)
        {
            Kill(process);
            await server.DisposeAsync();
            throw new ResticProxyException(line is null ? "timeout or exited before ready" : "invalid ready line");
        }

        return new ProxyHandle(process, server, reader, address);
    }

    private static string? TryReadAddress(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            return document.RootElement.TryGetProperty("address", out var address) ? address.GetString() : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    internal static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(true);
            }
        }
        catch (InvalidOperationException)
        {
        }
    }

    private sealed class ProxyHandle : IResticProxyHandle
    {
        private readonly Process process;
        private readonly NamedPipeServerStream pipe;
        private readonly SemaphoreSlim writing = new(1, 1);
        private readonly Task progress;
        private long uploaded;

        public ProxyHandle(Process process, NamedPipeServerStream pipe, StreamReader reader, string address)
        {
            this.process = process;
            this.pipe = pipe;
            Address = address;
            progress = Task.Run(async () =>
            {
                try
                {
                    while (await reader.ReadLineAsync() is { } line)
                    {
                        if (ProxyMessages.UploadedBytes(line) is { } total)
                        {
                            Interlocked.Exchange(ref uploaded, total);
                        }
                    }
                }
                catch (IOException)
                {
                }
                catch (ObjectDisposedException)
                {
                }
            });
        }

        public string Address { get; }

        public long UploadedBytes => Interlocked.Read(ref uploaded);

        public Task SetThrottleAsync(Throttle throttle) =>
            SendAsync(new { type = "throttle", throttle = new { bytesPerSec = throttle.BytesPerSec, quietHours = throttle.QuietHours } });

        public Task NetworkChangedAsync() => SendAsync(new { type = "network-changed" });

        private async Task SendAsync(object control)
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(control).Append((byte)'\n').ToArray();
            await writing.WaitAsync();
            try
            {
                await pipe.WriteAsync(bytes);
                await pipe.FlushAsync();
            }
            finally
            {
                writing.Release();
            }
        }

        public async ValueTask DisposeAsync()
        {
            Kill(process);
            await pipe.DisposeAsync();
            await progress;
            process.Dispose();
        }
    }
}

internal static class ProxyMessages
{
    public static long? UploadedBytes(string line)
    {
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            return root.TryGetProperty("type", out var type) && type.GetString() == "progress"
                && root.TryGetProperty("uploadedBytes", out var bytes) && bytes.TryGetInt64(out var value)
                ? value
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
