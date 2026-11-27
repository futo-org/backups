using System.Globalization;

using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Restic;

public sealed record SnapshotEntry(string Name, string Path, ResticNodeKind Kind, long? Size = null, DateTimeOffset? Modified = null)
{
    public bool IsDirectory => Kind == ResticNodeKind.Directory;

    public string? ParentPath => ResticTreePath.Parent(Path);
}

public sealed class SnapshotListingException(string line) : Exception(Text.ErrorCouldNotReadFolderListing)
{
    public string Line { get; } = line;
}

public static class SnapshotListing
{
    public static string FolderName(string path)
    {
        var trimmed = path.TrimEnd('\\', '/');
        var index = trimmed.LastIndexOfAny(['\\', '/']);
        var name = index >= 0 ? trimmed[(index + 1)..] : trimmed;
        return name.Length == 0 ? path : name;
    }

    public static IReadOnlyList<SnapshotEntry> Roots(IEnumerable<string> snapshotPaths) =>
        Sorted(snapshotPaths.Select(path => new SnapshotEntry(FolderName(path), ResticTreePath.FromLocal(path), ResticNodeKind.Directory)));

    public static IReadOnlyList<SnapshotEntry> Parse(string output, string directory)
    {
        IReadOnlyList<ResticNode> nodes;
        try
        {
            nodes = ResticOutput.ParseNodes(output);
        }
        catch (UnreadableResticOutputException error)
        {
            throw new SnapshotListingException(error.Line);
        }

        return Sorted(nodes
            .Where(node => ResticTreePath.Parent(node.Path) == directory)
            .Select(node => new SnapshotEntry(node.Name, node.Path, node.Kind, node.Size, node.Modified)));
    }

    public static IReadOnlyList<SnapshotEntry> Sorted(IEnumerable<SnapshotEntry> entries) => entries
        .OrderByDescending(entry => entry.IsDirectory)
        .ThenBy(entry => entry.Name, StringComparer.Create(CultureInfo.CurrentCulture, CompareOptions.NumericOrdering | CompareOptions.IgnoreCase))
        .ThenBy(entry => entry.Path, StringComparer.Ordinal)
        .ToList();
}

public sealed record RestoreStep(int Part, int PartCount, string Name, RestoreProgress? Progress = null)
{
    public string Title => PartCount > 1 ? string.Format(CultureInfo.CurrentCulture, Text.StatusRestoringPart, Part, PartCount) : Text.StatusRestoring;

    public double? Fraction => Progress is { HasStarted: true } progress ? progress.FractionDone : null;

    public double? OverallFraction => PartCount == 1 ? Fraction : null;

    public string Subtitle(bool namingPart = true)
    {
        var parts = new List<string>();
        if (namingPart && PartCount > 1)
        {
            parts.Add(Name);
        }

        if (Progress is { HasStarted: true } progress)
        {
            if (progress.TotalBytes > 0)
            {
                parts.Add(string.Format(CultureInfo.CurrentCulture, Text.StatusTransferred, Format.Bytes(progress.BytesRestored), Format.Bytes(progress.TotalBytes)));
            }

            parts.Add(string.Format(CultureInfo.CurrentCulture, progress.TotalFiles == 1 ? Text.StatusItemsRestoredOfOne : Text.StatusItemsRestoredOfMany, progress.FilesRestored, progress.TotalFiles));
        }
        else
        {
            parts.Add(Text.StatusBringingFilesBack);
        }

        return string.Join(" · ", parts);
    }
}
