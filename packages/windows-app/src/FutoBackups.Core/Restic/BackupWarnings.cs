using System.Globalization;
using System.Text.Json.Serialization;

using FutoBackups.Core.Strings;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Restic;

public sealed record BackupWarning(
    [property: JsonPropertyName("path")] string Path,
    [property: JsonPropertyName("reason")] string Reason);

public sealed record BackupWarnings(
    [property: JsonPropertyName("items")] IReadOnlyList<BackupWarning> Items,
    [property: JsonPropertyName("total")] int Total)
{
    public const int ItemLimit = 500;

    public static readonly BackupWarnings None = new([], 0);

    public bool IsTruncated => Total > Items.Count;

    public string? Summary => Total switch
    {
        0 => null,
        1 => Text.StatusCouldNotBackUpOneFile,
        _ => string.Format(CultureInfo.CurrentCulture, Text.StatusCouldNotBackUpFiles, Total),
    };

    public string Headline => Total == 1 ? Text.StatusHeadlineOneFile : string.Format(CultureInfo.CurrentCulture, Text.StatusHeadlineFiles, Total);

    public string ListTitle => IsTruncated ? string.Format(CultureInfo.CurrentCulture, Text.StatusShowingFirstOf, Items.Count, Total) : string.Format(CultureInfo.CurrentCulture, Text.StatusAllCount, Total);

    public string ListText() => string.Join('\n', Items.Select(item => $"{EscapingLineBreaks(item.Path)}: {EscapingLineBreaks(item.Reason)}"));

    internal static string EscapingLineBreaks(string text) => text.Replace("\n", "\\n").Replace("\r", "\\r");

    public static BackupWarnings Collect(string stderr, int limit = ItemLimit)
    {
        var collector = new Collector(limit);
        foreach (var problem in ResticOutput.ItemProblems(stderr))
        {
            collector.Add(problem.Item, Reason(problem), problem.DuringScan);
        }

        return collector.Warnings;
    }

    private static string Reason(ResticItemProblem problem) => problem.Kind switch
    {
        ResticProblemKind.Missing => Text.StatusDoesNotExist,
        ResticProblemKind.Inaccessible => Text.StatusCannotBeAccessed,
        _ when problem.Message.Length == 0 => problem.Message,
        _ => char.ToUpperInvariant(problem.Message[0]) + problem.Message[1..],
    };

    private sealed class Collector(int limit)
    {
        private readonly List<BackupWarning> items = [];
        private readonly HashSet<string> seen = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, int> scanReasonIndices = new(StringComparer.OrdinalIgnoreCase);
        private int total;

        public BackupWarnings Warnings => new(items.ToList(), total);

        public void Add(string path, string reason, bool duringScan)
        {
            if (!seen.Add(path))
            {
                if (!duringScan && scanReasonIndices.Remove(path, out var index))
                {
                    items[index] = items[index] with { Reason = reason };
                }

                return;
            }

            total++;
            if (items.Count >= limit) return;
            if (duringScan)
            {
                scanReasonIndices[path] = items.Count;
            }

            items.Add(new BackupWarning(path, reason));
        }
    }
}
