using System.Globalization;

using FutoBackups.Core;
using FutoBackups.Core.State;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.Tests.State;

public class ScheduleTests
{
    private static readonly TimeZoneInfo Paris = TimeZoneInfo.FindSystemTimeZoneById("Europe/Paris");
    private static readonly TimeZoneInfo Toronto = TimeZoneInfo.FindSystemTimeZoneById("America/Toronto");

    private static DateTimeOffset At(TimeZoneInfo zone, int year, int month, int day, int hour = 0, int minute = 0)
    {
        var local = new DateTime(year, month, day, hour, minute, 0);
        return new DateTimeOffset(local, zone.GetUtcOffset(local));
    }

    [Fact]
    public void ManualNeverSchedulesARun()
    {
        var now = At(Paris, 2026, 6, 10, 15, 30);
        Assert.Null(Schedule.Manual.NextRun(null, now, Paris));
        Assert.False(Schedule.Manual.IsDue(now.AddHours(-2), now, Paris));
    }

    [Theory]
    [InlineData(null, 3600, false)]
    [InlineData(7200, -3600, true)]
    [InlineData(600, 3000, false)]
    public void HourlyRunsAnHourAfterTheLastRun(int? lastAgo, int nextIn, bool due)
    {
        var now = At(Paris, 2026, 6, 10, 15, 30);
        DateTimeOffset? lastRun = lastAgo is { } seconds ? now.AddSeconds(-seconds) : null;
        Assert.Equal(now.AddSeconds(nextIn), Schedule.Hourly.NextRun(lastRun, now, Paris));
        Assert.Equal(due, Schedule.Hourly.IsDue(lastRun, now, Paris));
    }

    public static TheoryData<DateTimeOffset, DateTimeOffset?, DateTimeOffset, bool> DailyCases => new()
    {
        { At(Paris, 2026, 6, 10, 9), null, At(Paris, 2026, 6, 10, 12), false },
        { At(Paris, 2026, 6, 10, 15, 30), null, At(Paris, 2026, 6, 11, 12), false },
        { At(Paris, 2026, 6, 10, 15, 30), At(Paris, 2026, 6, 10, 8), At(Paris, 2026, 6, 10, 12), true },
        { At(Paris, 2026, 6, 10, 15, 30), At(Paris, 2026, 6, 10, 12, 5), At(Paris, 2026, 6, 11, 12), false },
        { At(Paris, 2026, 6, 10, 12), At(Paris, 2026, 6, 9, 12), At(Paris, 2026, 6, 10, 12), true },
    };

    [Theory]
    [MemberData(nameof(DailyCases))]
    public void DailyRunsAtTheSlotAndCatchesUpOneMissedSlot(DateTimeOffset now, DateTimeOffset? last, DateTimeOffset expected, bool due)
    {
        var schedule = Schedule.Daily(12, 0);
        Assert.Equal(expected, schedule.NextRun(last, now, Paris));
        Assert.Equal(due, schedule.IsDue(last, now, Paris));
    }

    [Fact]
    public void DailyInTheSpringForwardGapResolvesOnceThatDay()
    {
        var schedule = Schedule.Daily(2, 30);
        var resolved = schedule.NextRun(null, At(Paris, 2026, 3, 29), Paris)!.Value;
        Assert.Equal(new DateTime(2026, 3, 29), TimeZoneInfo.ConvertTime(resolved, Paris).Date);
        Assert.True(resolved >= At(Paris, 2026, 3, 29, 3));
        Assert.False(schedule.IsDue(resolved, At(Paris, 2026, 3, 29, 4), Paris));
    }

    [Fact]
    public void DailyInTheRepeatedFallBackHourRunsOnceAtTheFirstOccurrence()
    {
        var schedule = Schedule.Daily(1, 30);
        var firstPass = DateTimeOffset.Parse("2026-11-01T05:30:00Z", CultureInfo.InvariantCulture);
        Assert.Equal(firstPass, schedule.NextRun(null, At(Toronto, 2026, 10, 31, 22), Toronto));
        var ranAt = firstPass.AddSeconds(20);
        foreach (var now in new[] { "2026-11-01T05:45:00Z", "2026-11-01T06:30:00Z", "2026-11-01T06:45:00Z" })
        {
            Assert.False(schedule.IsDue(ranAt, DateTimeOffset.Parse(now, CultureInfo.InvariantCulture), Toronto));
        }
    }

    [Fact]
    public void WeeklyRunsOnTheChosenWeekday()
    {
        var schedule = Schedule.Weekly(DayOfWeek.Monday, 12, 0);
        Assert.Equal(At(Toronto, 2026, 6, 8, 12), schedule.NextRun(null, At(Toronto, 2026, 6, 8, 9), Toronto));
        Assert.Equal(At(Toronto, 2026, 6, 15, 12), schedule.NextRun(null, At(Toronto, 2026, 6, 8, 13), Toronto));
        Assert.True(schedule.IsDue(At(Toronto, 2026, 6, 1, 12), At(Toronto, 2026, 6, 9, 9), Toronto));
    }

    [Fact]
    public void ASavedScheduleHoldsOnlyItsKindDayAndTime()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(Schedule.Weekly(DayOfWeek.Friday, 14, 30), ConfigStore.JsonOptions);
        Assert.Equal("""{"kind":"weekly","weekday":"friday","hour":14,"minute":30}""", json.Replace(" ", "").Replace("\n", "").Replace("\r", ""));
    }

    [Fact]
    public void TheSummaryNamesEveryKindOfSchedule()
    {
        Assert.Equal("Only when you start a backup", Schedule.Manual.Summary);
        Assert.Equal("Every hour", Schedule.Hourly.Summary);
        Assert.StartsWith("Every day at ", Schedule.Daily(14, 30).Summary);
        Assert.StartsWith($"Every {Format.Culture.DateTimeFormat.GetDayName(DayOfWeek.Friday)} at ", Schedule.Weekly(DayOfWeek.Friday, 14, 30).Summary);
    }

    [Fact]
    public void UpcomingRunsListTheNextWeeklySlots()
    {
        var now = At(Paris, 2026, 6, 10, 15, 30);

        var runs = Schedule.Weekly(DayOfWeek.Saturday, 12, 0).UpcomingRuns(now.AddDays(-1), now, Paris, 3);

        Assert.Equal<DateTimeOffset>([At(Paris, 2026, 6, 13, 12), At(Paris, 2026, 6, 20, 12), At(Paris, 2026, 6, 27, 12)], runs);
    }

    [Fact]
    public void UpcomingRunsStartWithAnOverdueRunAndThenFollowTheSchedule()
    {
        var now = At(Paris, 2026, 6, 10, 15, 30);

        var runs = Schedule.Daily(12, 0).UpcomingRuns(At(Paris, 2026, 6, 8, 12), now, Paris, 3);

        Assert.Equal<DateTimeOffset>([At(Paris, 2026, 6, 10, 12), At(Paris, 2026, 6, 11, 12), At(Paris, 2026, 6, 12, 12)], runs);
    }

    [Fact]
    public void AManualScheduleHasNoUpcomingRuns()
    {
        Assert.Empty(Schedule.Manual.UpcomingRuns(null, At(Paris, 2026, 6, 10), Paris, 3));
    }

    [Fact]
    public void DefaultTimesAreSpreadAcrossMiddayInFiveMinuteSteps()
    {
        var times = Enumerable.Range(0, 200).Select(seed => Schedule.SpreadDefault(new Random(seed))).ToList();

        Assert.All(times, schedule =>
        {
            Assert.Equal(ScheduleKind.Daily, schedule.Kind);
            Assert.InRange(schedule.Hour * 60 + schedule.Minute, 11 * 60, 13 * 60 + 55);
            Assert.Equal(0, schedule.Minute % 5);
        });
        Assert.True(times.Distinct().Count() > 10);
    }

    [Theory]
    [InlineData("0 3 * * *", CronCheck.Valid)]
    [InlineData("not a schedule", CronCheck.Invalid)]
    [InlineData("0 0 30 2 *", CronCheck.NeverRuns)]
    [InlineData("*/10 * * * *", CronCheck.TooFrequent)]
    public void CustomSchedulesAreCheckedBeforeSaving(string cron, CronCheck expected)
    {
        Assert.Equal(expected, Schedule.Check(cron, At(Paris, 2026, 6, 10, 15, 30), Paris));
    }

    [Fact]
    public void ACustomScheduleRunsAtItsNextOccurrenceAndCatchesUpAMissedOne()
    {
        var schedule = Schedule.Custom("0 3 * * *");
        var now = At(Paris, 2026, 6, 10, 15, 30);

        Assert.Equal(At(Paris, 2026, 6, 11, 3), schedule.NextRun(At(Paris, 2026, 6, 10, 3, 5), now, Paris));
        Assert.True(schedule.IsDue(At(Paris, 2026, 6, 8, 3), now, Paris));
    }
}
