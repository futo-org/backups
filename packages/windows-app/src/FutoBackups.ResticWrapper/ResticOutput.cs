using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace FutoBackups.ResticWrapper;

public sealed record BackupProgress(double PercentDone = 0, int TotalFiles = 0, int FilesDone = 0, long TotalBytes = 0, long BytesDone = 0, int? SecondsRemaining = null);

public sealed record BackupSummary(
    int FilesNew = 0,
    int FilesChanged = 0,
    int FilesUnmodified = 0,
    long DataAdded = 0,
    int TotalFilesProcessed = 0,
    long TotalBytesProcessed = 0,
    string? SnapshotId = null);

public abstract record ResticMessage
{
    public sealed record Status(BackupProgress Progress) : ResticMessage;

    public sealed record Summary(BackupSummary Value) : ResticMessage;

    public sealed record Error(string Message) : ResticMessage;

    public sealed record Other : ResticMessage;
}

public sealed record Snapshot(
    string Id,
    string ShortId,
    DateTimeOffset Time,
    IReadOnlyList<string> Paths,
    string Hostname,
    IReadOnlyList<string> Tags,
    int? TotalFilesProcessed,
    long? TotalBytesProcessed,
    long? DataAdded);

public sealed record ResticKey(string Id, bool Current);

public sealed class UnreadableSnapshotTimeException(string shortId) : FormatException($"restic wrote a time for snapshot {shortId} that could not be read")
{
    public string ShortId { get; } = shortId;
}

public enum ResticNodeKind
{
    Directory,
    File,
    Symlink,
    Other,
}

public sealed record ResticNode(string Name, string Path, ResticNodeKind Kind, long? Size, DateTimeOffset? Modified);

public sealed class UnreadableResticOutputException(string line) : FormatException("restic wrote a line that is not JSON")
{
    public string Line { get; } = line;
}

public enum ResticProblemKind
{
    Error,
    Missing,
    Inaccessible,
}

public sealed record ResticItemProblem(string Item, string Message, ResticProblemKind Kind, bool DuringScan = false);

public sealed record RestoreProgress(double PercentDone = 0, int TotalFiles = 0, int FilesRestored = 0, long TotalBytes = 0, long BytesRestored = 0)
{
    public bool HasStarted => FilesRestored > 0 || BytesRestored > 0;

    public double FractionDone => TotalBytes == 0 && TotalFiles > 0 ? Math.Min(1, (double)FilesRestored / TotalFiles) : PercentDone;
}

public static class ResticExitCode
{
    public const int Success = 0;
    public const int CouldNotReadSource = 3;
    public const int RepositoryDoesNotExist = 10;
    public const int LockFailed = 11;
    public const int WrongPassword = 12;
}

public static class ResticOutput
{
    private static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    public static ResticMessage ParseLine(string line)
    {
        var kind = TryDecode<MessageKind>(line);
        switch (kind?.MessageType)
        {
            case "status" when TryDecode<StatusLine>(line) is { } status:
                return new ResticMessage.Status(new BackupProgress(
                    status.PercentDone ?? 0, status.TotalFiles ?? 0, status.FilesDone ?? 0, status.TotalBytes ?? 0, status.BytesDone ?? 0, status.SecondsRemaining));
            case "summary" when TryDecode<SummaryLine>(line) is { } summary:
                return new ResticMessage.Summary(new BackupSummary(
                    summary.FilesNew ?? 0, summary.FilesChanged ?? 0, summary.FilesUnmodified ?? 0, summary.DataAdded ?? 0,
                    summary.TotalFilesProcessed ?? 0, summary.TotalBytesProcessed ?? 0, summary.SnapshotId));
            case "error" when TryDecode<ErrorLine>(line) is { Error.Message: { } message } error:
                return new ResticMessage.Error(error.Item is { } item ? $"{item}: {message}" : message);
            default:
                return new ResticMessage.Other();
        }
    }

    public static IReadOnlyList<Snapshot> ParseSnapshots(string json) =>
        (JsonSerializer.Deserialize<List<SnapshotLine>>(json, Options) ?? []).Select(line => new Snapshot(
            line.Id,
            line.ShortId,
            ParseTimestamp(line.Time) ?? throw new UnreadableSnapshotTimeException(line.ShortId),
            line.Paths,
            line.Hostname,
            line.Tags ?? [],
            line.Summary?.TotalFilesProcessed,
            line.Summary?.TotalBytesProcessed,
            line.Summary?.DataAdded)).ToList();

    public static long ParseStatsTotalSize(string json) => JsonSerializer.Deserialize<StatsLine>(json, Options)!.TotalSize;

    public static string ParseVersion(string json) => JsonSerializer.Deserialize<VersionLine>(json, Options)!.Version;

    public static IReadOnlyList<ResticKey> ParseKeys(string json) => JsonSerializer.Deserialize<List<ResticKey>>(json, Options) ?? [];

    public static string? LastItemError(string stderr) =>
        stderr.Split('\n').Select(line => ParseLine(line.Trim())).OfType<ResticMessage.Error>().LastOrDefault()?.Message;

    public static string? LastError(string stderr)
    {
        string? lastErrorMessage = null;
        string? lastLine = null;
        foreach (var raw in stderr.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            lastLine = line;
            switch (TryDecode<MessageKind>(line)?.MessageType)
            {
                case "exit_error" when TryDecode<ExitErrorLine>(line) is { } exitError:
                    return exitError.Message;
                case "error" when TryDecode<ErrorLine>(line) is { Error.Message: { } message } error:
                    lastErrorMessage = error.Item is { } item ? $"{item}: {message}" : message;
                    break;
            }
        }

        return lastErrorMessage ?? lastLine;
    }

    public static IReadOnlyList<ResticItemProblem> ItemProblems(string stderr)
    {
        var problems = new List<ResticItemProblem>();
        foreach (var record in stderr.Split('\n'))
        {
            var line = record.TrimEnd('\r');
            if (SkippedSource(line) is { } skipped)
            {
                problems.Add(skipped);
                continue;
            }

            if (TryDecode<ErrorLine>(line.Trim()) is { MessageType: "error", Item: { Length: > 0 } item, Error.Message: { } message } error)
            {
                problems.Add(new ResticItemProblem(item, WithoutRepeatedItem(message, item), ResticProblemKind.Error, error.During == "scan"));
            }
        }

        return problems;
    }

    public static IReadOnlyList<ResticNode> ParseNodes(string output)
    {
        var nodes = new List<ResticNode>();
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            NodeLine? node;
            try
            {
                node = JsonSerializer.Deserialize<NodeLine>(line, Options);
            }
            catch (JsonException)
            {
                throw new UnreadableResticOutputException(line);
            }

            if (node is not { MessageType: "node", Name: { } name, Path: { } path }) continue;
            nodes.Add(new ResticNode(name, path, KindOf(node.Type), node.Size, node.Mtime is { } mtime ? ParseTimestamp(mtime) : null));
        }

        return nodes;
    }

    public static (bool IsSummary, RestoreProgress Progress)? ParseRestoreLine(string line)
    {
        if (TryDecode<RestoreLine>(line.TrimStart()) is not { } status) return null;
        var progress = new RestoreProgress(status.PercentDone ?? 0, status.TotalFiles ?? 0, status.FilesRestored ?? 0, status.TotalBytes ?? 0, status.BytesRestored ?? 0);
        return status.MessageType switch
        {
            "status" => (false, progress),
            "summary" => (true, progress with { PercentDone = 1 }),
            _ => null,
        };
    }

    public static DateTimeOffset? ParseTimestamp(string text) =>
        DateTimeOffset.TryParse(TruncateFraction(text), CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) ? date : null;

    private static string TruncateFraction(string text)
    {
        var dot = text.IndexOf('.');
        if (dot < 0) return text;
        var end = dot + 1;
        while (end < text.Length && char.IsAsciiDigit(text[end]))
        {
            end++;
        }

        var digits = text[(dot + 1)..end];
        digits = digits.Length > 7 ? digits[..7] : digits;
        return text[..dot] + "." + digits + text[end..];
    }

    private static readonly (string Suffix, ResticProblemKind Kind)[] SkippedSourceSuffixes =
    [
        (" does not exist, skipping", ResticProblemKind.Missing),
        (" cannot be accessed, skipping", ResticProblemKind.Inaccessible),
    ];

    private static ResticItemProblem? SkippedSource(string line)
    {
        if (line.StartsWith('{')) return null;
        foreach (var (suffix, kind) in SkippedSourceSuffixes)
        {
            if (line.EndsWith(suffix, StringComparison.Ordinal) && line.Length > suffix.Length) return new ResticItemProblem(line[..^suffix.Length], string.Empty, kind);
        }

        return null;
    }

    private static string WithoutRepeatedItem(string message, string item)
    {
        var start = 0;
        var spelling = item + ": ";
        var index = message.IndexOf(spelling, StringComparison.Ordinal);
        while (index >= 0)
        {
            start = Math.Max(start, index + spelling.Length);
            index = message.IndexOf(spelling, index + spelling.Length, StringComparison.Ordinal);
        }

        var remainder = message[start..].Trim();
        return remainder.Length == 0 ? message.Trim() : remainder;
    }

    private static ResticNodeKind KindOf(string? type) => type switch
    {
        "dir" => ResticNodeKind.Directory,
        "file" => ResticNodeKind.File,
        "symlink" => ResticNodeKind.Symlink,
        _ => ResticNodeKind.Other,
    };

    private static T? TryDecode<T>(string line) where T : class
    {
        if (!line.StartsWith('{')) return null;
        try
        {
            return JsonSerializer.Deserialize<T>(line, Options);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private sealed record MessageKind(string MessageType);

    private sealed record StatusLine(double? PercentDone, int? TotalFiles, int? FilesDone, long? TotalBytes, long? BytesDone, int? SecondsRemaining);

    private sealed record SummaryLine(int? FilesNew, int? FilesChanged, int? FilesUnmodified, long? DataAdded, int? TotalFilesProcessed, long? TotalBytesProcessed, string? SnapshotId);

    private sealed record ErrorPayload(string? Message);

    private sealed record ErrorLine(ErrorPayload? Error, string? Item, string? During = null, string? MessageType = null);

    private sealed record NodeLine(string? MessageType, string? Name, string? Type, string? Path, long? Size, string? Mtime);

    private sealed record RestoreLine(string MessageType, double? PercentDone, int? TotalFiles, int? FilesRestored, long? TotalBytes, long? BytesRestored);

    private sealed record ExitErrorLine(string Message);

    private sealed record SnapshotSummary(int? TotalFilesProcessed, long? TotalBytesProcessed, long? DataAdded);

    private sealed record SnapshotLine(string Id, string ShortId, string Time, IReadOnlyList<string> Paths, string Hostname, IReadOnlyList<string>? Tags, SnapshotSummary? Summary);

    private sealed record StatsLine(long TotalSize);

    private sealed record VersionLine(string Version);
}
