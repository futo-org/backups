using System.Globalization;

using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.Onboarding;

public enum StandardFolder
{
    Documents,
    Desktop,
    Pictures,
    Videos,
    Music,
    Downloads,
}

public enum FolderBundle
{
    Essentials,
    EssentialsAndMedia,
    Everything,
}

public static class FolderBundles
{
    public static readonly FolderBundle[] All = Enum.GetValues<FolderBundle>();

    public static StandardFolder[] StandardFolders(this FolderBundle bundle) => bundle switch
    {
        FolderBundle.Essentials => [StandardFolder.Documents, StandardFolder.Desktop],
        FolderBundle.EssentialsAndMedia => [StandardFolder.Documents, StandardFolder.Desktop, StandardFolder.Pictures, StandardFolder.Videos, StandardFolder.Music],
        _ => [],
    };

    public static string Title(this FolderBundle bundle) => bundle switch
    {
        FolderBundle.Essentials => Text.FlowBundleEssentials,
        FolderBundle.EssentialsAndMedia => Text.FlowBundleEssentialsAndMedia,
        _ => Text.FlowBundleEverything,
    };

    public static string Detail(this FolderBundle bundle) => bundle switch
    {
        FolderBundle.Essentials => Text.FlowBundleEssentialsDetail,
        FolderBundle.EssentialsAndMedia => Text.FlowBundleEssentialsAndMediaDetail,
        _ => Text.FlowBundleEverythingDetail,
    };
}

public abstract record FolderChoice
{
    public sealed record Home : FolderChoice;

    public sealed record Standard(StandardFolder Folder) : FolderChoice;

    public sealed record Other(string Path) : FolderChoice;
}

public interface IKnownFolders
{
    string Home { get; }

    string PathOf(StandardFolder folder);
}

public sealed class WindowsKnownFolders : IKnownFolders
{
    public string Home { get; } = System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile);

    public string PathOf(StandardFolder folder) => folder switch
    {
        StandardFolder.Documents => System.Environment.GetFolderPath(System.Environment.SpecialFolder.MyDocuments),
        StandardFolder.Desktop => System.Environment.GetFolderPath(System.Environment.SpecialFolder.DesktopDirectory),
        StandardFolder.Pictures => System.Environment.GetFolderPath(System.Environment.SpecialFolder.MyPictures),
        StandardFolder.Videos => System.Environment.GetFolderPath(System.Environment.SpecialFolder.MyVideos),
        StandardFolder.Music => System.Environment.GetFolderPath(System.Environment.SpecialFolder.MyMusic),
        _ => Path.Combine(Home, "Downloads"),
    };
}

public sealed class FolderSelection
{
    private readonly IKnownFolders known;
    private readonly List<FolderChoice> choices;
    private readonly HashSet<FolderChoice> selected = [];

    public FolderSelection(IKnownFolders known, FolderBundle bundle = FolderBundle.EssentialsAndMedia, Func<string, bool>? isDirectory = null)
    {
        this.known = known;
        isDirectory ??= Directory.Exists;
        choices = Enum.GetValues<StandardFolder>().Select(folder => (FolderChoice)new FolderChoice.Standard(folder))
            .Append(new FolderChoice.Home())
            .Where(choice => isDirectory(PathOf(choice)))
            .ToList();
        Apply(bundle);
    }

    public FolderBundle Bundle { get; private set; }

    public IReadOnlyList<FolderChoice> Choices => choices;

    public string PathOf(FolderChoice choice) => choice switch
    {
        FolderChoice.Home => known.Home,
        FolderChoice.Standard standard => known.PathOf(standard.Folder),
        FolderChoice.Other other => other.Path,
        _ => string.Empty,
    };

    public string NameOf(FolderChoice choice) => choice is FolderChoice.Home ? Text.FlowEntireUserFolder : Path.GetFileName(PathOf(choice).TrimEnd('\\'));

    public void Apply(FolderBundle bundle)
    {
        Bundle = bundle;
        var preset = bundle.StandardFolders().Select(folder => (FolderChoice)new FolderChoice.Standard(folder)).ToHashSet();
        if (bundle == FolderBundle.Everything)
        {
            preset.Add(new FolderChoice.Home());
        }

        var others = selected.Where(choice => choice is FolderChoice.Other).ToList();
        selected.Clear();
        foreach (var choice in choices.Where(preset.Contains).Concat(others))
        {
            selected.Add(choice);
        }
    }

    public bool IsSelected(FolderChoice choice) => selected.Contains(choice);

    public FolderChoice? CoveringChoice(FolderChoice choice)
    {
        var path = PathOf(choice);
        return choices.FirstOrDefault(other => other != choice && selected.Contains(other) && IsAncestor(PathOf(other), path));
    }

    public bool IsIncluded(FolderChoice choice) => selected.Contains(choice) || CoveringChoice(choice) is not null;

    public void Set(FolderChoice choice, bool isSelected)
    {
        if (!choices.Contains(choice)) return;
        if (isSelected)
        {
            selected.Add(choice);
        }
        else
        {
            selected.Remove(choice);
        }
    }

    public void AddOthers(IEnumerable<string> paths)
    {
        foreach (var path in paths.Select(Path.GetFullPath))
        {
            if (choices.FirstOrDefault(choice => string.Equals(PathOf(choice), path, StringComparison.OrdinalIgnoreCase)) is { } existing)
            {
                selected.Add(existing);
                continue;
            }

            var other = new FolderChoice.Other(path);
            choices.Add(other);
            selected.Add(other);
        }
    }

    public IReadOnlyList<string> Paths => choices.Where(choice => selected.Contains(choice) && CoveringChoice(choice) is null).Select(PathOf).ToList();

    public bool CanContinue => Paths.Count > 0;

    public static bool IsAncestor(string ancestor, string path)
    {
        var prefix = ancestor.EndsWith('\\') ? ancestor : ancestor + "\\";
        return !string.Equals(path, ancestor, StringComparison.OrdinalIgnoreCase) && path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase);
    }
}

public abstract record FolderSize
{
    public sealed record Calculating : FolderSize;

    public sealed record Unavailable : FolderSize;

    public sealed record Bytes(long Value) : FolderSize;

    public sealed record AtLeast(long Value) : FolderSize;

    public string Text => this switch
    {
        Calculating => Strings.Text.FlowSizeCalculating,
        Bytes bytes => string.Format(CultureInfo.CurrentCulture, Strings.Text.FlowSizeAbout, Format.Bytes(bytes.Value)),
        AtLeast atLeast => string.Format(CultureInfo.CurrentCulture, Strings.Text.FlowSizeAtLeast, Format.Bytes(atLeast.Value)),
        _ => Strings.Text.CommonUnknown,
    };
}

public static class FolderSizer
{
    public static FolderSize Measure(string folder, IReadOnlyList<string> excludes, CancellationToken cancellation)
    {
        if (!Directory.Exists(folder)) return new FolderSize.Unavailable();
        long total = 0;
        var partial = false;
        var options = new EnumerationOptions { IgnoreInaccessible = false, AttributesToSkip = FileAttributes.ReparsePoint };
        var pending = new Stack<string>([folder]);
        while (pending.Count > 0)
        {
            cancellation.ThrowIfCancellationRequested();
            var directory = pending.Pop();
            if (Exclusions.IsExcluded(directory, excludes)) continue;
            try
            {
                foreach (var entry in new DirectoryInfo(directory).EnumerateFileSystemInfos("*", options))
                {
                    if (entry is DirectoryInfo)
                    {
                        pending.Push(entry.FullName);
                    }
                    else if (!Engine.PlaceholderScanner.IsCloudOnly(entry.Attributes) && !Exclusions.IsExcluded(entry.FullName, excludes))
                    {
                        var file = (FileInfo)entry;
                        total += file.Length;
                    }
                }
            }
            catch (Exception error) when (error is UnauthorizedAccessException or IOException)
            {
                partial = true;
            }
        }

        return partial ? new FolderSize.AtLeast(total) : new FolderSize.Bytes(total);
    }

    public static string TotalText(IEnumerable<FolderSize> sizes)
    {
        long bytes = 0;
        var partial = false;
        foreach (var size in sizes)
        {
            switch (size)
            {
                case FolderSize.Calculating:
                    return Text.FlowSizeCalculating;
                case FolderSize.Bytes value:
                    bytes += value.Value;
                    break;
                case FolderSize.AtLeast value:
                    bytes += value.Value;
                    partial = true;
                    break;
                default:
                    partial = true;
                    break;
            }
        }

        return string.Format(CultureInfo.CurrentCulture, partial ? Text.FlowSizeAtLeast : Text.FlowSizeAbout, Format.Bytes(bytes));
    }
}

public static class OnboardingConfig
{
    public static bool NeedsOnboarding(this AppConfig config) => config.OnboardingCompletedAt is null && config.Folders.Count == 0;

    public static AppConfig CompletingOnboarding(this AppConfig config, IEnumerable<string> chosen, DateTimeOffset date) => config with
    {
        Folders = config.Folders.Concat(chosen.Where(path => !config.Folders.Contains(path, StringComparer.OrdinalIgnoreCase))).ToList(),
        ScheduleAnchor = config.ScheduleAnchor ?? date,
        OnboardingCompletedAt = date,
    };
}
