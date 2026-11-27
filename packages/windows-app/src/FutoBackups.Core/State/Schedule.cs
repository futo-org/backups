using System.Globalization;
using System.Text.Json.Serialization;

using Cronos;

using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.State;

public enum ScheduleKind
{
    Manual,
    Hourly,
    Daily,
    Weekly,
    Custom,
}

public enum CronCheck
{
    Valid,
    Invalid,
    NeverRuns,
    TooFrequent,
}

public sealed record Schedule(
    [property: JsonPropertyName("kind")] ScheduleKind Kind,
    [property: JsonPropertyName("weekday")] DayOfWeek Weekday = DayOfWeek.Sunday,
    [property: JsonPropertyName("hour")] int Hour = 12,
    [property: JsonPropertyName("minute")] int Minute = 0,
    [property: JsonPropertyName("cron")] string? Cron = null)
{
    public static readonly Schedule Manual = new(ScheduleKind.Manual);

    public static readonly Schedule Hourly = new(ScheduleKind.Hourly);

    public static Schedule Daily(int hour, int minute) => new(ScheduleKind.Daily, DayOfWeek.Sunday, hour, minute);

    public static Schedule Weekly(DayOfWeek weekday, int hour, int minute) => new(ScheduleKind.Weekly, weekday, hour, minute);

    public const string ExampleCron = "0 3 * * *";

    public static Schedule Custom(string cron) => new(ScheduleKind.Custom, Cron: cron);

    public static CronCheck Check(string cron, DateTimeOffset now, TimeZoneInfo zone)
    {
        if (Parse(cron) is not { } expression) return CronCheck.Invalid;
        var runs = expression.GetOccurrences(now, now.AddYears(5), zone).Take(3).ToList();
        if (runs.Count == 0) return CronCheck.NeverRuns;
        return runs.Zip(runs.Skip(1)).Any(pair => pair.Second - pair.First < TimeSpan.FromHours(1)) ? CronCheck.TooFrequent : CronCheck.Valid;
    }

    public static Schedule SpreadDefault(Random random)
    {
        var slot = random.Next(36);
        return Daily(11 + slot / 12, slot % 12 * 5);
    }

    [JsonIgnore]
    public string Summary => Kind switch
    {
        ScheduleKind.Manual => Text.ScheduleOnlyWhenYouStart,
        ScheduleKind.Hourly => Text.ScheduleEveryHour,
        ScheduleKind.Daily => string.Format(CultureInfo.CurrentCulture, Text.ScheduleEveryDayAt, TimeText),
        ScheduleKind.Custom => string.Format(CultureInfo.CurrentCulture, Text.ScheduleCustomSummary, Cron),
        _ => string.Format(CultureInfo.CurrentCulture, Text.ScheduleEveryWeekdayAt, Format.Culture.DateTimeFormat.GetDayName(Weekday), TimeText),
    };

    private string TimeText => Format.Time(DateTimeOffset.Now.Date.AddHours(Hour).AddMinutes(Minute));

    public DateTimeOffset? NextRun(DateTimeOffset? lastRun, DateTimeOffset now, TimeZoneInfo zone)
    {
        switch (Kind)
        {
            case ScheduleKind.Manual:
                return null;
            case ScheduleKind.Hourly:
                return (lastRun ?? now).AddHours(1);
            case ScheduleKind.Custom:
                return Cron is { } cron && Parse(cron) is { } expression ? expression.GetNextOccurrence(lastRun ?? now, zone) : null;
        }

        var latest = Enumerable.Range(-7, 8).Reverse().Select(offset => Slot(offset, now, zone)).OfType<DateTimeOffset>().FirstOrDefault(slot => slot <= now);
        if (lastRun is { } previous && latest != default && previous < latest) return latest;
        return Enumerable.Range(0, 8).Select(offset => Slot(offset, now, zone)).OfType<DateTimeOffset>().First(slot => slot > now);
    }

    public IReadOnlyList<DateTimeOffset> UpcomingRuns(DateTimeOffset? lastRun, DateTimeOffset now, TimeZoneInfo zone, int count)
    {
        var runs = new List<DateTimeOffset>();
        var next = NextRun(lastRun, now, zone);
        while (next is { } run && runs.Count < count)
        {
            runs.Add(run);
            var after = run > now ? run : now;
            next = NextRun(after, after, zone);
        }

        return runs;
    }

    public bool IsDue(DateTimeOffset? lastRun, DateTimeOffset now, TimeZoneInfo zone) =>
        NextRun(lastRun, now, zone) is { } next && next <= now;

    private DateTimeOffset? Slot(int dayOffset, DateTimeOffset now, TimeZoneInfo zone)
    {
        var localNow = TimeZoneInfo.ConvertTime(now, zone);
        var day = localNow.Date.AddDays(dayOffset);
        if (Kind == ScheduleKind.Weekly && day.DayOfWeek != Weekday) return null;
        var local = day.AddHours(Hour).AddMinutes(Minute);
        while (zone.IsInvalidTime(local))
        {
            local = local.AddMinutes(1);
        }

        var offset = zone.IsAmbiguousTime(local) ? zone.GetAmbiguousTimeOffsets(local).Max() : zone.GetUtcOffset(local);
        return new DateTimeOffset(local, offset);
    }

    private static CronExpression? Parse(string cron) => CronExpression.TryParse(cron.Trim(), CronFormat.Standard, out var expression) ? expression : null;
}
