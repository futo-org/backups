using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace FutoBackups.Core.Support;

public sealed partial class PathRedactor(byte[]? key = null)
{
    private const int MaxExtensionLength = 8;

    private static readonly HashSet<string> PathFields = ["item", "current_files", "path", "paths", "name", "target", "excludes"];

    private readonly byte[] key = key ?? RandomNumberGenerator.GetBytes(32);

    [GeneratedRegex(@"^(?:/|[A-Za-z]:\\)")]
    private static partial Regex AbsolutePath();

    // Quotes, apostrophes, newlines and ": " are all legal in file names, so nothing inside a name reliably ends it. An
    // embedded path is redacted through the last ": " (where Go appends the error reason) or to the end of the message,
    // at the cost of also hiding any text between the path and that point.
    [GeneratedRegex(@"(?<=^|[\s""'(=\[])(?:/|[A-Za-z]:\\)(?:.*(?=: )|.*)", RegexOptions.Singleline)]
    private static partial Regex EmbeddedPath();

    [GeneratedRegex(@"://[^/\s@]+@")]
    private static partial Regex CredentialUrl();

    public string Placeholder(string path)
    {
        var digest = Convert.ToHexStringLower(HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(path)))[..12];
        var extension = Path.GetExtension(path.TrimEnd('"', '\'', '/', '\\'));
        return $"<path:{digest}{(extension.Length <= MaxExtensionLength ? extension : string.Empty)}>";
    }

    public string RedactText(string text) => EmbeddedPath().Replace(text, match => Placeholder(match.Value));

    public static string StripCredentials(string text) => CredentialUrl().Replace(text, "://***@");

    public string Redact(string line)
    {
        if (line.StartsWith('{') || line.StartsWith('['))
        {
            try
            {
                return RedactNode(JsonNode.Parse(line), false)?.ToJsonString() ?? "null";
            }
            catch (JsonException)
            {
                return RedactText(line);
            }
        }

        return RedactText(line);
    }

    public JsonNode? RedactNode(JsonNode? node, bool isPath) => node switch
    {
        JsonValue value when value.TryGetValue<string>(out var text) =>
            JsonValue.Create(isPath || AbsolutePath().IsMatch(text) ? Placeholder(text) : RedactText(text)),
        JsonArray array => new JsonArray(array.Select(item => RedactNode(item, isPath)).ToArray()),
        JsonObject entries => new JsonObject(entries.Select(entry => KeyValuePair.Create(entry.Key, RedactNode(entry.Value, PathFields.Contains(entry.Key))))),
        _ => node?.DeepClone(),
    };
}
