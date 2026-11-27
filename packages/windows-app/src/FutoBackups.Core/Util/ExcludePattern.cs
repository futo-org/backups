namespace FutoBackups.Core.Util;

public sealed class ExcludePattern
{
    private abstract record Part;

    private sealed record Root : Part;

    private sealed record AnyDepth : Part;

    private sealed record Literal(string Text) : Part;

    private sealed record Glob(string Pattern) : Part;

    private const string RootComponent = "/";

    private readonly Part[] parts;
    private readonly string? lastLiteral;

    private ExcludePattern(Part[] parts)
    {
        this.parts = parts;
        lastLiteral = parts[^1] is Literal literal ? literal.Text : null;
    }

    public static ExcludePattern? Parse(string pattern)
    {
        if (pattern.Length == 0 || pattern.StartsWith('!')) return null;
        var parts = new List<Part>();
        foreach (var component in Components(pattern))
        {
            if (component == RootComponent)
            {
                parts.Add(new Root());
            }
            else if (component == "**")
            {
                parts.Add(new AnyDepth());
            }
            else if (component.IndexOfAny(['[', ']', '*', '?']) >= 0)
            {
                if (!IsValidGlob(component)) return null;
                parts.Add(new Glob(component));
            }
            else
            {
                parts.Add(new Literal(component));
            }
        }

        return new ExcludePattern(parts.ToArray());
    }

    public bool Matches(string path) => Match(parts, Components(path), false);

    internal bool Matches(IReadOnlyList<string> components, bool endAnchored)
    {
        if (endAnchored && lastLiteral is not null && components[^1] != lastLiteral) return false;
        return Match(parts, components, endAnchored);
    }

    internal static List<string> Components(string path)
    {
        var components = CleanPath(path).ToLowerInvariant().Split('/').ToList();
        if (components[0].Length == 0)
        {
            components[0] = RootComponent;
        }

        if (components.Count == 2 && components[1].Length == 0)
        {
            components.RemoveAt(1);
        }

        return components;
    }

    internal static string CleanPath(string path)
    {
        if (path.Length == 0) return ".";
        var slashed = path.Replace('\\', '/');
        var rooted = slashed.StartsWith('/');
        var kept = new List<string>();
        foreach (var component in slashed.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            switch (component)
            {
                case ".":
                    continue;
                case "..":
                    if (kept.Count > 0 && kept[^1] != "..")
                    {
                        kept.RemoveAt(kept.Count - 1);
                    }
                    else if (!rooted)
                    {
                        kept.Add(component);
                    }

                    break;
                default:
                    kept.Add(component);
                    break;
            }
        }

        var joined = string.Join('/', kept);
        if (rooted) return "/" + joined;
        return joined.Length == 0 ? "." : joined;
    }

    private static bool Match(IReadOnlyList<Part> parts, IReadOnlyList<string> path, bool endAnchored)
    {
        var wildcard = parts.ToList().FindIndex(part => part is AnyDepth);
        if (wildcard >= 0)
        {
            var maxStars = path.Count - parts.Count + 1;
            if (maxStars < 0) return false;
            for (var stars = 0; stars <= maxStars; stars++)
            {
                var expanded = parts.Take(wildcard).Concat(Enumerable.Repeat<Part>(new Glob("*"), stars)).Concat(parts.Skip(wildcard + 1)).ToList();
                if (Match(expanded, path, endAnchored)) return true;
            }

            return false;
        }

        if (parts.Count == 0 || path.Count == 0 || parts.Count > path.Count) return false;
        var minOffset = 0;
        var maxOffset = path.Count - parts.Count;
        if (parts[0] is Root)
        {
            maxOffset = 0;
        }
        else if (path[0] == RootComponent)
        {
            minOffset = 1;
        }

        if (endAnchored)
        {
            minOffset = Math.Max(minOffset, path.Count - parts.Count);
        }

        for (var offset = maxOffset; offset >= minOffset; offset--)
        {
            if (parts.Select((part, index) => PartMatches(part, path[offset + index])).All(matched => matched)) return true;
        }

        return false;
    }

    private static bool PartMatches(Part part, string component) => part switch
    {
        Root => component == RootComponent,
        Literal literal => literal.Text == component,
        Glob glob => GlobMatches(glob.Pattern, component),
        _ => false,
    };

    private static bool GlobMatches(string pattern, string name)
    {
        var patternIndex = 0;
        var nameIndex = 0;
        int? starPattern = null;
        var starName = 0;
        while (nameIndex < name.Length)
        {
            if (patternIndex < pattern.Length && Step(pattern, patternIndex, name[nameIndex]) is { } next)
            {
                if (pattern[patternIndex] == '*')
                {
                    starPattern = patternIndex;
                    starName = nameIndex;
                    patternIndex++;
                    continue;
                }

                patternIndex = next;
                nameIndex++;
                continue;
            }

            if (starPattern is not { } star) return false;
            starName++;
            nameIndex = starName;
            patternIndex = star + 1;
        }

        while (patternIndex < pattern.Length && pattern[patternIndex] == '*')
        {
            patternIndex++;
        }

        return patternIndex == pattern.Length;
    }

    private static int? Step(string pattern, int index, char character)
    {
        switch (pattern[index])
        {
            case '*':
                return index;
            case '?':
                return index + 1;
            case '[':
                if (ParseClass(pattern, index) is not { } parsed) return null;
                var inClass = parsed.Ranges.Any(range => character >= range.Low && character <= range.High);
                return inClass != parsed.Negated ? parsed.End : null;
            default:
                return pattern[index] == character ? index + 1 : null;
        }
    }

    private static (List<(char Low, char High)> Ranges, bool Negated, int End)? ParseClass(string pattern, int start)
    {
        var index = start + 1;
        var negated = false;
        if (index < pattern.Length && pattern[index] == '^')
        {
            negated = true;
            index++;
        }

        var ranges = new List<(char Low, char High)>();
        while (true)
        {
            if (index < pattern.Length && pattern[index] == ']' && ranges.Count > 0) return (ranges, negated, index + 1);
            if (ClassCharacter(pattern, ref index) is not { } low) return null;
            var high = low;
            if (index < pattern.Length && pattern[index] == '-')
            {
                index++;
                if (ClassCharacter(pattern, ref index) is not { } upper) return null;
                high = upper;
            }

            if (low > high) return null;
            ranges.Add((low, high));
        }
    }

    private static char? ClassCharacter(string pattern, ref int index)
    {
        if (index >= pattern.Length || pattern[index] == '-' || pattern[index] == ']') return null;
        return pattern[index++];
    }

    private static bool IsValidGlob(string pattern)
    {
        var index = 0;
        while (index < pattern.Length)
        {
            if (pattern[index] != '[')
            {
                index++;
                continue;
            }

            if (ParseClass(pattern, index) is not { } parsed) return false;
            index = parsed.End;
        }

        return true;
    }
}
