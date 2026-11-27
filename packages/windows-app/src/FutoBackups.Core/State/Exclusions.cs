using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.State;

public enum ExclusionError
{
    Empty,
    AlreadyExcluded,
}

public sealed class ExclusionException(ExclusionError error)
    : Exception(error == ExclusionError.Empty ? Text.ErrorEnterFolderFilePattern : Text.ErrorAlreadyExcluded)
{
    public ExclusionError Error { get; } = error;
}

public static class Exclusions
{
    public static readonly string[][] DefaultExcludesByVersion =
    [
        [
            @"~\AppData\Local\Temp",
            @"~\AppData\Local\Microsoft\Windows\INetCache",
            @"~\AppData\Local\Microsoft\Windows\Explorer",
            @"~\AppData\Local\Packages\*\LocalCache",
            @"~\AppData\Local\Packages\*\TempState",
            @"~\AppData\Local\Packages\*\AC\INetCache",
            @"~\AppData\Local\CrashDumps",
            @"~\AppData\Local\Docker\wsl",
            @"~\AppData\Local\Packages\CanonicalGroupLimited.*\LocalState\ext4.vhdx",
            @"**\node_modules",
            @"**\$Recycle.Bin",
            @"**\System Volume Information",
            @"**\Thumbs.db",
            @"**\pagefile.sys",
            @"**\hiberfil.sys",
            @"**\swapfile.sys",
        ],
    ];

    public static readonly string[] DefaultExcludes = DefaultExcludesByVersion.SelectMany(version => version).ToArray();

    public static int CurrentDefaultsVersion => DefaultExcludesByVersion.Length;

    public static string[] Defaults(string home) => DefaultExcludes.Select(pattern => ExpandHome(pattern, home)).ToArray();

    public static bool IsDefault(string pattern, string home) => Defaults(home).Contains(pattern, StringComparer.OrdinalIgnoreCase);

    public static string PatternForPath(string path) => path.Replace("[", "[[]");

    public static string? NormalizedPattern(string input, string home)
    {
        var trimmed = input.Trim();
        if (trimmed.Length == 0) return null;
        var expanded = ExpandHome(trimmed, home);
        if (expanded.Length <= 1 || !(expanded.EndsWith('\\') || expanded.EndsWith('/')) || expanded.EndsWith(":\\", StringComparison.Ordinal)) return expanded;
        return expanded[..^1];
    }

    public static List<string> Adding(IReadOnlyList<string> patterns, IReadOnlyList<string> excludes)
    {
        var fresh = patterns.Where(pattern => !excludes.Contains(pattern, StringComparer.OrdinalIgnoreCase)).ToList();
        if (fresh.Count == 0) throw new ExclusionException(patterns.Count == 0 ? ExclusionError.Empty : ExclusionError.AlreadyExcluded);
        var result = excludes.ToList();
        foreach (var pattern in fresh.Where(pattern => !result.Contains(pattern, StringComparer.OrdinalIgnoreCase)))
        {
            result.Add(pattern);
        }

        return result;
    }

    public static bool IsExcluded(string path, IReadOnlyList<string> excludes) => excludes.Aggregate(false, (excluded, exclude) =>
        exclude.StartsWith('!')
            ? excluded && ExcludePattern.Parse(exclude[1..])?.Matches(path) != true
            : excluded || ExcludePattern.Parse(exclude)?.Matches(path) == true);

    public static List<string> Excluding(IReadOnlyList<string> paths, IReadOnlyList<string> excludes)
    {
        var result = excludes.ToList();
        foreach (var path in paths.Where(path => !IsExcluded(path, result)))
        {
            var literal = PatternForPath(path);
            result.RemoveAll(pattern => string.Equals(pattern, literal, StringComparison.OrdinalIgnoreCase));
            result.Add(literal);
        }

        return result;
    }

    public static bool WouldExcludeAnyFolder(string path, IReadOnlyList<string> folders) =>
        ExcludePattern.Parse(PatternForPath(path)) is { } exclusion && folders.Any(exclusion.Matches);

    public static List<string> RestoringDefaults(IReadOnlyList<string> excludes, string home) =>
        Defaults(home).Where(pattern => !excludes.Contains(pattern, StringComparer.OrdinalIgnoreCase)).Concat(excludes).ToList();

    public static string Label(string pattern, string home)
    {
        var literal = pattern.Replace("[[]", "[");
        return literal.StartsWith(@"**\", StringComparison.Ordinal) || literal.StartsWith("**/", StringComparison.Ordinal) ? literal[3..] : Format.AbbreviatedPath(literal, home);
    }

    public static IReadOnlyList<string> Matching(IReadOnlyList<string> patterns, string query, string home)
    {
        var needle = query.Trim();
        if (needle.Length == 0) return patterns;
        return patterns.Where(pattern =>
            pattern.Contains(needle, StringComparison.CurrentCultureIgnoreCase)
            || Label(pattern, home).Contains(needle, StringComparison.CurrentCultureIgnoreCase)).ToList();
    }

    public static string ExpandHome(string pattern, string home)
    {
        if (pattern == "~") return home;
        return pattern.StartsWith(@"~\", StringComparison.Ordinal) || pattern.StartsWith("~/", StringComparison.Ordinal) ? home + pattern[1..] : pattern;
    }
}
