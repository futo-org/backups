using System.Globalization;

namespace FutoBackups.ResticWrapper;

public sealed record ResticInvocation(IReadOnlyList<string> Arguments, IReadOnlyDictionary<string, string> Environment)
{
    public string? CurrentDirectory { get; init; }

    public bool RetainsStdout { get; init; } = true;
}

public abstract class ResticCommandBuilder<TSelf>(params string[] command) where TSelf : ResticCommandBuilder<TSelf>
{
    private readonly List<string> flags = [];
    private readonly List<string> positional = [];
    private readonly Dictionary<string, string> environment = [];
    private bool retainsStdout = true;

    private TSelf Self => (TSelf)this;

    public TSelf Repository(string repository) => Environment("RESTIC_REPOSITORY", repository);

    public TSelf Password(string password) => Environment("RESTIC_PASSWORD", password);

    public TSelf CacheDir(string directory) => Flag("--cache-dir", directory);

    public TSelf Option(string option) => Flag("--option", option);

    public TSelf PackSize(int? mebibytes) => Flag("--pack-size", mebibytes);

    public TSelf NoLock() => Flag("--no-lock");

    public TSelf ProgressFps(int framesPerSecond) => Environment("RESTIC_PROGRESS_FPS", framesPerSecond.ToString(CultureInfo.InvariantCulture));

    public TSelf DiscardStdout()
    {
        retainsStdout = false;
        return Self;
    }

    public ResticInvocation ToInvocation()
    {
        var arguments = new List<string>(command) { "--json" };
        arguments.AddRange(flags);
        if (positional.Count > 0)
        {
            arguments.Add("--");
            arguments.AddRange(positional);
        }

        return new ResticInvocation(arguments, new Dictionary<string, string>(environment)) { RetainsStdout = retainsStdout };
    }

    protected TSelf Flag(string name, params IEnumerable<string> values)
    {
        flags.Add(name);
        flags.AddRange(values);
        return Self;
    }

    protected TSelf Flag(string name, int? value) => value is { } number ? Flag(name, number.ToString(CultureInfo.InvariantCulture)) : Self;

    protected TSelf Repeated(string name, IEnumerable<string> values)
    {
        foreach (var value in values)
        {
            Flag(name, value);
        }

        return Self;
    }

    protected TSelf Positional(params IEnumerable<string> values)
    {
        positional.AddRange(values);
        return Self;
    }

    protected TSelf Environment(string name, string value)
    {
        environment[name] = value;
        return Self;
    }
}
