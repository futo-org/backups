using System.Text.Json;

using FutoBackups.Core.State;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.State;

public class RetentionTests
{
    private static SnapshotRetention Within(string within) => new(new RetentionPolicy { KeepWithin = within });

    private static SnapshotRetention Last(int count) => new(new RetentionPolicy { KeepLast = count });

    private static SnapshotRetention Daily(string daily) => new(new RetentionPolicy { KeepWithinDaily = daily });

    [Fact]
    public void PresetsMirrorTheImmichIntegrationAndDefaultToSixtyDays()
    {
        Assert.Equal(Within("15d"), RetentionPreset.Days15.Retention());
        Assert.Equal(Last(2), RetentionPreset.LatestTwo.Retention());
        Assert.Equal(SnapshotRetention.KeepAll, RetentionPreset.Never.Retention());
        Assert.Equal(SnapshotRetention.Standard, RetentionPresets.Standard.Retention());
        Assert.Equal(Within("60d"), SnapshotRetention.Standard);
        Assert.Equal(RetentionPreset.Days90, RetentionPresets.Matching(Within("90d")));
        Assert.Null(RetentionPresets.Matching(Within("45d")));
    }

    [Fact]
    public void RetentionEncodesAsTheOrchestrationApiPolicyShapeOrKeepAll()
    {
        var options = new JsonSerializerOptions { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };
        Assert.Equal("""{"keepAll":true}""", JsonSerializer.Serialize(SnapshotRetention.KeepAll, options));
        Assert.Equal("""{"keepWithin":"60d"}""", JsonSerializer.Serialize(SnapshotRetention.Standard, options));
        Assert.Equal("""{"keepLast":2}""", JsonSerializer.Serialize(Last(2), options));
        Assert.Equal(Last(5), JsonSerializer.Deserialize<SnapshotRetention>("""{"keepLast":5}""", options));
        Assert.Equal(SnapshotRetention.KeepAll, JsonSerializer.Deserialize<SnapshotRetention>("""{"keepAll":true}""", options));
    }

    [Theory]
    [InlineData("60d", 0, 0, 60, 0, "60d")]
    [InlineData(" 1y2m3d4h ", 1, 2, 3, 4, "1y2m3d4h")]
    [InlineData("4h3d2m1y", 1, 2, 3, 4, "1y2m3d4h")]
    [InlineData("1d2y", 2, 0, 1, 0, "2y1d")]
    [InlineData("2h1d", 0, 0, 1, 2, "1d2h")]
    [InlineData("6m", 0, 6, 0, 0, "6m")]
    [InlineData("0y5d", 0, 0, 5, 0, "5d")]
    [InlineData("012h", 0, 0, 0, 12, "12h")]
    [InlineData("9999y", 9999, 0, 0, 0, "9999y")]
    public void DurationsAcceptResticUnitsInAnyOrderAndNormaliseThem(string text, int years, int months, int days, int hours, string canonical)
    {
        var parsed = RetentionDuration.Parse(text);
        Assert.Equal(new RetentionDuration(years, months, days, hours), parsed);
        Assert.Equal(canonical, parsed.Text);
    }

    [Theory]
    [InlineData("", RetentionInputError.InvalidDuration)]
    [InlineData("60", RetentionInputError.InvalidDuration)]
    [InlineData("d", RetentionInputError.InvalidDuration)]
    [InlineData("1w", RetentionInputError.InvalidDuration)]
    [InlineData("2D", RetentionInputError.InvalidDuration)]
    [InlineData("-1d", RetentionInputError.InvalidDuration)]
    [InlineData("1.5d", RetentionInputError.InvalidDuration)]
    [InlineData("1d1d", RetentionInputError.InvalidDuration)]
    [InlineData("1d2h1d", RetentionInputError.InvalidDuration)]
    [InlineData("0d1d", RetentionInputError.InvalidDuration)]
    [InlineData("1d 2h", RetentionInputError.InvalidDuration)]
    [InlineData("0d", RetentionInputError.ZeroDuration)]
    [InlineData("0y0m0d0h", RetentionInputError.ZeroDuration)]
    [InlineData("10000d", RetentionInputError.DurationTooLong)]
    [InlineData("99999999999999999999d", RetentionInputError.DurationTooLong)]
    public void DurationsRejectAnythingResticWouldRefuseOrMisread(string text, RetentionInputError error) =>
        Assert.Equal(error, Assert.Throws<RetentionInputException>(() => RetentionDuration.Parse(text)).Error);

    [Theory]
    [InlineData(0, 0, 60, 0, "60 days")]
    [InlineData(0, 0, 1, 0, "1 day")]
    [InlineData(1, 6, 0, 0, "1 year and 6 months")]
    [InlineData(2, 1, 3, 4, "2 years, 1 month, 3 days and 4 hours")]
    public void DurationsDescribeThemselvesInWords(int years, int months, int days, int hours, string text) =>
        Assert.Equal(text, new RetentionDuration(years, months, days, hours).Description);

    public static TheoryData<SnapshotRetention, string> Summaries => new()
    {
        { SnapshotRetention.Standard, "Keep the last 60 days" },
        { Last(2), "Keep the latest 2 backups" },
        { Last(1), "Keep the latest backup" },
        { SnapshotRetention.KeepAll, "Keep all snapshots" },
        { new(new RetentionPolicy { KeepWithinHourly = "2d", KeepWithinDaily = "1m", KeepWithinWeekly = "6m" }), "Hourly for 2 days, daily for 1 month, weekly for 6 months" },
        { new(new RetentionPolicy { KeepLast = 3, KeepWithin = "7d", KeepWithinYearly = "10y" }), "Latest 3 backups, all for 7 days, yearly for 10 years" },
        { new(new RetentionPolicy()), "Keep all snapshots until you correct the retention setting" },
    };

    [Theory]
    [MemberData(nameof(Summaries))]
    public void PoliciesDescribeThemselvesForTheUi(SnapshotRetention retention, string summary) => Assert.Equal(summary, retention.Summary);

    [Fact]
    public void TelemetryNamesTheResticRulesWithoutPaths()
    {
        Assert.Equal("keep-within 60d", SnapshotRetention.Standard.TelemetryValue);
        Assert.Equal("keep-all", SnapshotRetention.KeepAll.TelemetryValue);
        Assert.Equal("keep-last 2, keep-within-monthly 2y", new SnapshotRetention(new RetentionPolicy { KeepLast = 2, KeepWithinMonthly = "2y" }).TelemetryValue);
        Assert.Equal("invalid", new SnapshotRetention(new RetentionPolicy()).TelemetryValue);
    }

    public static TheoryData<RetentionPolicy, RetentionInputError> InvalidPolicies => new()
    {
        { new RetentionPolicy(), RetentionInputError.NoRules },
        { new RetentionPolicy { KeepLast = 0 }, RetentionInputError.NotAPositiveNumber },
        { new RetentionPolicy { KeepLast = -2 }, RetentionInputError.NotAPositiveNumber },
        { new RetentionPolicy { KeepLast = 100_001 }, RetentionInputError.NumberTooLarge },
        { new RetentionPolicy { KeepLast = 2, KeepWithinWeekly = "1w" }, RetentionInputError.InvalidDuration },
        { new RetentionPolicy { KeepWithinYearly = "0y" }, RetentionInputError.ZeroDuration },
    };

    [Theory]
    [MemberData(nameof(InvalidPolicies))]
    public void PolicyValidationChecksEveryRuleAndRequiresAtLeastOne(RetentionPolicy policy, RetentionInputError error) =>
        Assert.Equal(error, Assert.Throws<RetentionInputException>(() => policy.Validated()).Error);

    [Fact]
    public void ValidationNormalisesDurationsToResticCanonicalForm()
    {
        var validated = new RetentionPolicy { KeepLast = 2, KeepWithin = " 012d ", KeepWithinMonthly = "0y2m" }.Validated();
        Assert.Equal(new RetentionPolicy { KeepLast = 2, KeepWithin = "12d", KeepWithinMonthly = "2m" }, validated.Policy);
        Assert.Equal(["forget", "--json", "--keep-last", "2", "--keep-within", "12d", "--keep-within-monthly", "2m"], validated.ApplyTo(ResticCli.Forget()).ToInvocation().Arguments);
    }

    public static TheoryData<SnapshotRetention, SnapshotRetention, bool> Stricter => new()
    {
        { SnapshotRetention.Standard, SnapshotRetention.Standard, false },
        { SnapshotRetention.Standard, RetentionPreset.Days90.Retention(), false },
        { SnapshotRetention.Standard, SnapshotRetention.KeepAll, false },
        { SnapshotRetention.Standard, RetentionPreset.Days30.Retention(), true },
        { SnapshotRetention.Standard, RetentionPreset.LatestTwo.Retention(), true },
        { SnapshotRetention.KeepAll, SnapshotRetention.Standard, true },
        { Last(2), Last(3), false },
        { Last(2), Last(1), true },
        { Last(2), SnapshotRetention.Standard, true },
        { SnapshotRetention.Standard, Within("2m"), true },
        { SnapshotRetention.Standard, Within("3m"), false },
        { SnapshotRetention.Standard, Daily("1y"), true },
        { Daily("1m"), Within("1y"), false },
        { Daily("1m"), Daily("2m"), false },
        { Daily("2m"), Daily("1m"), true },
        { new(new RetentionPolicy { KeepLast = 2, KeepWithinDaily = "1m" }), new(new RetentionPolicy { KeepLast = 2, KeepWithin = "7d", KeepWithinDaily = "1m", KeepWithinYearly = "5y" }), false },
        { new(new RetentionPolicy()), SnapshotRetention.Standard, true },
        { SnapshotRetention.Standard, new(new RetentionPolicy()), false },
    };

    [Theory]
    [MemberData(nameof(Stricter))]
    public void StricterRetentionNeedsConfirmationLooserRetentionDoesNot(SnapshotRetention current, SnapshotRetention proposed, bool mayDeleteMore) =>
        Assert.Equal(mayDeleteMore, proposed.MayDeleteMoreThan(current));

    [Theory]
    [InlineData("24h", "1d", true)]
    [InlineData("1d", "24h", true)]
    [InlineData("25h", "1d1h", true)]
    [InlineData("47h", "1d", true)]
    [InlineData("1d", "48h", false)]
    [InlineData("720h", "1m", true)]
    [InlineData("1m", "768h", false)]
    [InlineData("8760h", "1y", true)]
    [InlineData("365d", "1y", false)]
    [InlineData("1y", "365d", true)]
    [InlineData("366d", "1y", true)]
    [InlineData("1m", "31d", false)]
    [InlineData("1m", "30d", true)]
    [InlineData("28d", "1m", false)]
    [InlineData("29d", "1m", true)]
    [InlineData("2d", "1d23h", true)]
    [InlineData("2h1d", "1d2h", false)]
    [InlineData("1d2h", "1d", true)]
    [InlineData("1d", "1d2h", false)]
    public void CalendarUnitsOnlyCoverElapsedHoursWithADayToSpare(string current, string proposed, bool mayDeleteMore) =>
        Assert.Equal(mayDeleteMore, Within(proposed).MayDeleteMoreThan(Within(current)));

    [Theory]
    [InlineData(RetentionPreset.LatestTwo, new[] { "pc" }, true)]
    [InlineData(RetentionPreset.Days60, new[] { "pc", "other" }, true)]
    [InlineData(RetentionPreset.Days15, null, true)]
    [InlineData(RetentionPreset.LatestTwo, new[] { "other" }, false)]
    [InlineData(RetentionPreset.LatestTwo, new string[0], false)]
    [InlineData(RetentionPreset.Never, new[] { "pc" }, false)]
    [InlineData(RetentionPreset.Never, null, false)]
    public void ResumingABackupConfirmsAnyPolicyThatCanDeleteThisPcsSnapshots(RetentionPreset preset, string[]? hostnames, bool mayDelete) =>
        Assert.Equal(mayDelete, preset.Retention().MayDeleteResumedSnapshots(hostnames, "pc"));

    [Fact]
    public void ADraftStartsFromThePolicyAndProducesAValidatedPolicy()
    {
        var policy = new RetentionPolicy { KeepLast = 3, KeepWithinDaily = "1m" };
        var draft = new RetentionDraft(policy);
        Assert.Equal("3", draft[RetentionField.Last]);
        Assert.Equal("1m", draft[RetentionField.Daily]);
        Assert.Equal(string.Empty, draft[RetentionField.Within]);
        Assert.Equal(policy, draft.Policy());
        draft[RetentionField.Last] = string.Empty;
        draft[RetentionField.Yearly] = "10y";
        Assert.Equal(new RetentionPolicy { KeepWithinDaily = "1m", KeepWithinYearly = "10y" }, draft.Policy());
        Assert.Empty(draft.Errors);
    }

    [Theory]
    [InlineData("0", RetentionInputError.NotAPositiveNumber)]
    [InlineData("-1", RetentionInputError.NotAPositiveNumber)]
    [InlineData("1.5", RetentionInputError.NotAPositiveNumber)]
    [InlineData("100001", RetentionInputError.NumberTooLarge)]
    [InlineData("9999999999", RetentionInputError.NumberTooLarge)]
    public void ADraftReportsAnErrorForAnInvalidCount(string text, RetentionInputError error)
    {
        var draft = new RetentionDraft();
        draft[RetentionField.Last] = text;
        Assert.Equal(new Dictionary<RetentionField, RetentionInputError> { [RetentionField.Last] = error }, draft.Errors);
    }

    [Fact]
    public void AnEmptyDraftAsksForAtLeastOneRule()
    {
        var draft = new RetentionDraft();
        Assert.Empty(draft.Errors);
        Assert.Equal(RetentionInputError.NoRules, Assert.Throws<RetentionInputException>(() => draft.Policy()).Error);
    }
}
