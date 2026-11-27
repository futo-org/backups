using System.Globalization;
using System.Text.Json.Serialization;

namespace FutoBackups.Core.State;

public sealed record Throttle(
    [property: JsonPropertyName("bytesPerSec")] long BytesPerSec = 0,
    [property: JsonPropertyName("quietHours")] string QuietHours = "")
{
    public static readonly Throttle Unthrottled = new();

    public long? ActiveLimit(DateTime localTime)
    {
        if (BytesPerSec <= 0) return null;
        if (State.QuietHours.ParseRange(QuietHours) is not var (start, end)) return BytesPerSec;
        var minute = localTime.Hour * 60 + localTime.Minute;
        var from = start.Hour * 60 + start.Minute;
        var until = end.Hour * 60 + end.Minute;
        var quiet = from == until || (from < until ? minute >= from && minute < until : minute >= from || minute < until);
        return quiet ? null : BytesPerSec;
    }
}

public enum UploadLimitError
{
    NotAWholeNumber,
    TooLarge,
}

public sealed class UploadLimitException(UploadLimitError error) : Exception(UploadLimit.Message(error))
{
    public UploadLimitError Error { get; } = error;
}

public static class UploadLimit
{
    public const long MaxKilobytesPerSecond = 10_000_000;

    public static string Message(UploadLimitError error) => error == UploadLimitError.NotAWholeNumber
        ? Strings.Text.SettingsUploadLimitNotAWholeNumber
        : string.Format(CultureInfo.CurrentCulture, Strings.Text.SettingsUploadLimitTooLarge, MaxKilobytesPerSecond);

    public static long BytesPerSecond(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return 0;
        if (!trimmed.All(char.IsAsciiDigit)) throw new UploadLimitException(UploadLimitError.NotAWholeNumber);
        if (trimmed.Length > 9 || long.Parse(trimmed, CultureInfo.InvariantCulture) > MaxKilobytesPerSecond) throw new UploadLimitException(UploadLimitError.TooLarge);
        return long.Parse(trimmed, CultureInfo.InvariantCulture) * 1024;
    }

    public static string Text(long bytesPerSecond) => bytesPerSecond > 0 ? (bytesPerSecond / 1024).ToString(CultureInfo.InvariantCulture) : string.Empty;
}

public readonly record struct ClockTime(int Hour, int Minute)
{
    public static ClockTime? Parse(string text)
    {
        var parts = text.Split(':');
        if (parts.Length != 2 || !int.TryParse(parts[0], out var hour) || !int.TryParse(parts[1], out var minute)) return null;
        if (hour is < 0 or >= 24 || minute is < 0 or >= 60) return null;
        return new ClockTime(hour, minute);
    }

    public string Text => $"{Hour:00}:{Minute:00}";
}

public sealed class QuietHoursException() : Exception(Strings.Text.SettingsQuietHoursSame);

public sealed record QuietHours
{
    public QuietHours(ClockTime start, ClockTime end)
    {
        if (start == end) throw new QuietHoursException();
        Start = start;
        End = end;
    }

    public static readonly QuietHours Default = new(new ClockTime(22, 0), new ClockTime(7, 0));

    public ClockTime Start { get; }

    public ClockTime End { get; }

    public string Text => $"{Start.Text}-{End.Text}";

    public static QuietHours? Parse(string text) =>
        ParseRange(text) is var (start, end) && start != end ? new QuietHours(start, end) : null;

    internal static (ClockTime Start, ClockTime End)? ParseRange(string text)
    {
        var parts = text.Split('-', 2);
        if (parts.Length != 2 || ClockTime.Parse(parts[0]) is not { } start || ClockTime.Parse(parts[1]) is not { } end) return null;
        return (start, end);
    }
}
