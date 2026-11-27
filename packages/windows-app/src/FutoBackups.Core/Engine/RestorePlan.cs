using System.Text;

using FutoBackups.Core.Restic;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Engine;

public sealed record RestoreItem(string SnapshotPath, string Target);

public abstract record RestoreBatch
{
    public sealed record Folder(RestoreItem Item) : RestoreBatch;

    public sealed record Children(IReadOnlyList<SnapshotEntry> Entries, string Parent) : RestoreBatch;

    public string Name => this switch
    {
        Folder folder => SnapshotListing.FolderName(folder.Item.SnapshotPath),
        Children { Entries: [var only] } => only.Name,
        Children children => SnapshotListing.FolderName(children.Parent),
        _ => string.Empty,
    };
}

internal sealed class RestoredItems
{
    private readonly List<string> paths = [];
    private readonly HashSet<string> names = [];

    public IReadOnlyList<string> Paths => paths;

    public IReadOnlySet<string> Names => names;

    public void Add(string path)
    {
        paths.Add(path);
        names.Add(RestorePlan.NameKey(Path.GetFileName(path)));
    }
}

public static class RestorePlan
{
    public const string StagingName = ".FUTO Backups Restore";
    public const int MaxNameLength = 255;
    public const int ArgumentBudget = 24 * 1024;

    public static IReadOnlyList<RestoreItem> Items(IReadOnlyList<string> snapshotPaths, string target, Func<string, bool>? exists = null)
    {
        exists ??= path => Path.Exists(path);
        var taken = new HashSet<string>();
        return snapshotPaths.Select(path =>
        {
            var baseName = SnapshotListing.FolderName(path).TrimEnd(':');
            var name = baseName;
            var suffix = 2;
            while (taken.Contains(NameKey(name)) || exists(Path.Combine(target, name)))
            {
                name = NumberedName(baseName, suffix++, false);
            }

            taken.Add(NameKey(name));
            return new RestoreItem(ResticTreePath.FromLocal(path), Path.Combine(target, name));
        }).ToList();
    }

    public static string ClaimTarget(RestoreItem item, IReadOnlySet<string> taken, Func<string, bool> createDirectory)
    {
        var parent = Path.GetDirectoryName(item.Target)!;
        var baseName = SnapshotListing.FolderName(item.SnapshotPath).TrimEnd(':');
        var name = Path.GetFileName(item.Target);
        var suffix = 2;
        while (true)
        {
            var candidate = Path.Combine(parent, name);
            if (!taken.Contains(NameKey(name)) && createDirectory(candidate)) return candidate;
            name = NumberedName(baseName, suffix++, false);
        }
    }

    public static IReadOnlyList<RestoreBatch> Batches(IReadOnlyList<SnapshotEntry> entries, string target, int argumentBudget = ArgumentBudget)
    {
        var slots = new List<RestoreBatch>();
        var groups = new Dictionary<string, List<SnapshotEntry>>();
        foreach (var entry in entries)
        {
            if (entry.ParentPath is not { } parent || parent == ResticTreePath.Root)
            {
                slots.Add(new RestoreBatch.Folder(new RestoreItem(entry.Path, Path.Combine(target, SnapshotListing.FolderName(entry.Path)))));
                continue;
            }

            if (!groups.TryGetValue(parent, out var group))
            {
                group = [];
                groups[parent] = group;
                slots.Add(new RestoreBatch.Children([], parent));
            }

            group.Add(entry);
        }

        return slots.SelectMany(slot => slot is RestoreBatch.Children children
            ? StagingGroups(groups[children.Parent], argumentBudget).Select(group => (RestoreBatch)new RestoreBatch.Children(group, children.Parent))
            : [slot]).ToList();
    }

    private static List<List<SnapshotEntry>> StagingGroups(List<SnapshotEntry> children, int argumentBudget)
    {
        var groups = new List<List<SnapshotEntry>>();
        var current = new List<SnapshotEntry>();
        var names = new HashSet<string>();
        var bytes = 0;
        foreach (var child in children)
        {
            var size = "--include".Length + 3 + RestoreCommand.LiteralPattern(child.Name).Length * 2;
            if (current.Count > 0 && (names.Contains(NameKey(child.Name)) || bytes + size > argumentBudget))
            {
                groups.Add(current);
                current = [];
                names = [];
                bytes = 0;
            }

            current.Add(child);
            names.Add(NameKey(child.Name));
            bytes += size;
        }

        if (current.Count > 0)
        {
            groups.Add(current);
        }

        return groups;
    }

    public static string ClaimName(SnapshotEntry entry, string target, IReadOnlySet<string> taken, Func<string, bool> place)
    {
        for (var number = 1; ; number++)
        {
            var name = NumberedName(entry.Name, number, !entry.IsDirectory);
            var candidate = Path.Combine(target, name);
            if (!taken.Contains(NameKey(name)) && place(candidate)) return candidate;
        }
    }

    public static string ClaimStaging(string target, IReadOnlySet<string> restoring, Func<string, bool> createDirectory)
    {
        for (var number = 1; ; number++)
        {
            var name = NumberedName(StagingName, number, false);
            var candidate = Path.Combine(target, name);
            if (!restoring.Contains(NameKey(name)) && createDirectory(candidate))
            {
                File.SetAttributes(candidate, File.GetAttributes(candidate) | FileAttributes.Hidden);
                return candidate;
            }
        }
    }

    internal static string NumberedName(string name, int number, bool keepingExtension)
    {
        if (number <= 1) return name;
        var extension = Path.GetExtension(name);
        var keepsExtension = keepingExtension && extension.Length > 1;
        var stem = keepsExtension ? name[..^extension.Length] : name;
        var suffix = keepsExtension ? $" {number}{extension}" : $" {number}";
        while (stem.Length > 0 && (stem + suffix).Normalize(NormalizationForm.FormD).Length > MaxNameLength)
        {
            stem = stem[..^1];
        }

        return stem + suffix;
    }

    internal static string NameKey(string name) => name.ToLowerInvariant();

    public static bool CreateDirectoryExclusively(string path)
    {
        if (Path.Exists(path)) return false;
        Directory.CreateDirectory(path);
        return true;
    }

    public static bool MoveExclusively(string source, string destination)
    {
        if (Path.Exists(destination)) return false;
        if (Directory.Exists(source))
        {
            Directory.Move(source, destination);
        }
        else
        {
            File.Move(source, destination, false);
        }

        return true;
    }

    public static void RemoveStaging(string path)
    {
        if (Directory.Exists(path))
        {
            Directory.Delete(path, true);
        }
    }
}
