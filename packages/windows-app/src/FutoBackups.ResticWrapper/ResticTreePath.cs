namespace FutoBackups.ResticWrapper;

public static class ResticTreePath
{
    public const string Root = "/";

    public static string FromLocal(string localPath)
    {
        if (localPath.StartsWith(@"\\", StringComparison.Ordinal) && Path.GetPathRoot(localPath) is { Length: > 0 } root)
        {
            var rest = localPath[root.Length..].Trim('\\').Replace('\\', '/');
            return "/" + root.TrimEnd('\\') + (rest.Length > 0 ? "/" + rest : string.Empty);
        }

        var slashed = localPath.Replace('\\', '/').TrimEnd('/');
        if (slashed.Length >= 2 && slashed[1] == ':') return "/" + slashed[0] + slashed[2..];
        return slashed.StartsWith('/') ? slashed : "/" + slashed;
    }

    public static string ToLocal(string treePath)
    {
        var parts = treePath.TrimStart('/').Split('/');
        if (parts[0].Length == 1 && char.IsAsciiLetter(parts[0][0])) return parts[0] + ":\\" + string.Join('\\', parts[1..]);
        if (parts[0].StartsWith(@"\\", StringComparison.Ordinal)) return string.Join('\\', parts);
        return treePath.Replace('/', '\\');
    }

    public static string? Parent(string treePath)
    {
        if (treePath == Root) return null;
        var slash = treePath.LastIndexOf('/');
        if (slash < 0) return null;
        return slash == 0 ? Root : treePath[..slash];
    }
}
