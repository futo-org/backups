using FutoBackups.Core.Api;
using FutoBackups.Core.Support;

namespace FutoBackups.Core;

public sealed class Telemetry(PathRedactor? redactor = null)
{
    public const string Client = "windows";

    public const string FutoCloudBackendId = "d0368cdd-39ae-40e1-91d6-d81815c65c7e";

    private readonly PathRedactor redactor = redactor ?? new PathRedactor();

    public StructuredLog Log(string summary, IReadOnlyDictionary<string, object?> data, string version)
    {
        var attributes = new Dictionary<string, object?>();
        foreach (var (name, value) in data)
        {
            attributes[name] = value switch
            {
                string text => Clean(text),
                Exception error => Describe(error),
                _ => value,
            };
        }

        attributes["version"] = version;
        attributes["client"] = Client;
        return new StructuredLog(summary, attributes);
    }

    private string Clean(string text) => redactor.RedactText(PathRedactor.StripCredentials(text));

    private Dictionary<string, object?> Describe(Exception error) => new()
    {
        ["type"] = error.GetType().Name,
        ["message"] = Clean(error.Message),
        ["stack"] = error.StackTrace is { } stack ? Clean(stack) : null,
        ["cause"] = error.InnerException is { } inner ? Describe(inner) : null,
    };
}
