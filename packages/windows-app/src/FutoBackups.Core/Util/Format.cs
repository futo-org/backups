using System.Globalization;

using FutoBackups.Core.Strings;

namespace FutoBackups.Core.Util;

public static class Format
{
    public static CultureInfo Culture { get; set; } = CultureInfo.CurrentCulture;

    public static string Bytes(long? value)
    {
        var bytes = value ?? 0;
        if (bytes == 0) return Text.FormatZeroKb;
        if (Math.Abs(bytes) < 1000) return bytes == 1 ? Text.FormatOneByte : string.Format(CultureInfo.CurrentCulture, Text.FormatBytes, bytes);
        string[] units = [Text.FormatKb, Text.FormatMb, Text.FormatGb, Text.FormatTb, Text.FormatPb];
        double scaled = bytes;
        var unit = -1;
        while (Math.Abs(scaled) >= 1000 && unit < units.Length - 1)
        {
            scaled /= 1000;
            unit++;
        }

        var text = unit == 0 ? Math.Round(scaled).ToString("0", Culture) : scaled.ToString(scaled < 100 ? "0.#" : "0", Culture);
        return string.Format(CultureInfo.CurrentCulture, units[unit], text);
    }

    public static string Rate(double bytesPerSecond)
    {
        var bits = Math.Max(0, bytesPerSecond) * 8;
        var (value, format) = bits switch
        {
            < 1_000_000 => (bits / 1_000, Text.FormatKbitPerSecond),
            < 1_000_000_000 => (bits / 1_000_000, Text.FormatMbitPerSecond),
            _ => (bits / 1_000_000_000, Text.FormatGbitPerSecond),
        };
        return string.Format(CultureInfo.CurrentCulture, format, value.ToString(value < 10 ? "0.0" : "0", Culture));
    }

    public static string Time(DateTimeOffset date) => date.ToLocalTime().ToString("t", Culture);

    public static string List(IReadOnlyList<string> items) => items.Count switch
    {
        0 => string.Empty,
        1 => items[0],
        _ => string.Format(CultureInfo.CurrentCulture, Text.ListAnd, string.Join(Text.ListSeparator, items.Take(items.Count - 1)), items[^1]),
    };

    public static string Relative(DateTimeOffset date, bool inSentence = false)
    {
        var local = date.ToLocalTime().DateTime;
        var today = DateTime.Today;
        var time = Time(date);
        if (local.Date == today) return string.Format(CultureInfo.CurrentCulture, inSentence ? Text.FormatTodayAtInSentence : Text.FormatTodayAt, time);
        if (local.Date == today.AddDays(1)) return string.Format(CultureInfo.CurrentCulture, inSentence ? Text.FormatTomorrowAtInSentence : Text.FormatTomorrowAt, time);
        if (local.Date == today.AddDays(-1)) return string.Format(CultureInfo.CurrentCulture, inSentence ? Text.FormatYesterdayAtInSentence : Text.FormatYesterdayAt, time);
        return $"{local.ToString("ddd d MMM", Culture)}, {time}";
    }

    public static string Absolute(DateTimeOffset date) => date.ToLocalTime().ToString("f", Culture);

    public static string Day(DateTime day)
    {
        if (day.Date == DateTime.Today) return Text.FormatToday;
        if (day.Date == DateTime.Today.AddDays(-1)) return Text.FormatYesterday;
        return day.ToString("dddd d MMMM", Culture);
    }

    public static string Duration(int seconds)
    {
        if (seconds < 60) return Text.FormatUnderAMinuteLeft;
        var span = TimeSpan.FromSeconds(seconds);
        return span.TotalHours >= 1
            ? string.Format(CultureInfo.CurrentCulture, Text.FormatHoursMinutesLeft, (int)span.TotalHours, span.Minutes)
            : string.Format(CultureInfo.CurrentCulture, Text.FormatMinutesLeft, span.Minutes);
    }

    public static string Count(int count, string one, string many) => count == 1 ? one : string.Format(CultureInfo.CurrentCulture, many, count);

    public static string AbbreviatedPath(string path, string home) =>
        path.Equals(home, StringComparison.OrdinalIgnoreCase) || path.StartsWith(home + "\\", StringComparison.OrdinalIgnoreCase)
            ? "~" + path[home.Length..]
            : path;
}
