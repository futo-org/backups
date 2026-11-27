using System.Diagnostics;
using System.Text;

namespace FutoBackups.ResticWrapper;

public sealed record ResticResult(int ExitCode, string Stdout, string Stderr);

public interface IResticExecuting
{
    Task<ResticResult> RunAsync(ResticInvocation invocation, Action<string>? onLine = null, CancellationToken cancellation = default);
}

public sealed class ResticRunner(string executable) : IResticExecuting
{
    private static readonly string[] InheritedVariables =
        ["SystemRoot", "SystemDrive", "windir", "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA", "APPDATA", "ProgramData", "PATH", "PATHEXT", "COMPUTERNAME", "USERNAME", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"];

    public async Task<ResticResult> RunAsync(ResticInvocation invocation, Action<string>? onLine = null, CancellationToken cancellation = default)
    {
        cancellation.ThrowIfCancellationRequested();
        var start = new ProcessStartInfo(executable)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        if (invocation.CurrentDirectory is { } directory)
        {
            start.WorkingDirectory = directory;
        }

        foreach (var argument in invocation.Arguments)
        {
            start.ArgumentList.Add(argument);
        }

        start.Environment.Clear();
        foreach (var name in InheritedVariables)
        {
            if (Environment.GetEnvironmentVariable(name) is { } value)
            {
                start.Environment[name] = value;
            }
        }

        foreach (var (name, value) in invocation.Environment)
        {
            start.Environment[name] = value;
        }

        using var process = new Process { StartInfo = start };
        process.Start();
        var stdout = new StringBuilder();
        var reading = Task.Run(async () =>
        {
            while (await process.StandardOutput.ReadLineAsync(CancellationToken.None) is { } line)
            {
                if (invocation.RetainsStdout)
                {
                    stdout.AppendLine(line);
                }

                onLine?.Invoke(line);
            }
        }, CancellationToken.None);
        var stderr = process.StandardError.ReadToEndAsync(CancellationToken.None);
        await using (cancellation.Register(() => Stop(process)))
        {
            await process.WaitForExitAsync(CancellationToken.None);
            await reading;
        }

        cancellation.ThrowIfCancellationRequested();
        return new ResticResult(process.ExitCode, stdout.ToString(), await stderr);
    }

    private static void Stop(Process process)
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
}
