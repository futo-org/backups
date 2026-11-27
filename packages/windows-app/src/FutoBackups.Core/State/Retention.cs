using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

using FutoBackups.Core.Strings;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.State;

public enum RetentionInputError
{
    InvalidDuration,
    ZeroDuration,
    DurationTooLong,
    NotAPositiveNumber,
    NumberTooLarge,
    NoRules,
}

public sealed class RetentionInputException(RetentionInputError error) : Exception(Retention.Message(error))
{
    public RetentionInputError Error { get; } = error;
}

public static class Retention
{
    public const int MaxKeepLast = 100_000;

    public static string Message(RetentionInputError error) => error switch
    {
        RetentionInputError.InvalidDuration => Text.RetentionInvalidDuration,
        RetentionInputError.ZeroDuration => Text.RetentionZeroDuration,
        RetentionInputError.DurationTooLong => Text.RetentionDurationTooLong,
        RetentionInputError.NotAPositiveNumber => Text.RetentionNotAPositiveNumber,
        RetentionInputError.NumberTooLarge => string.Format(CultureInfo.CurrentCulture, Text.RetentionNumberTooLarge, MaxKeepLast),
        _ => Text.RetentionNoRules,
    };
}

public readonly record struct RetentionDuration(int Years = 0, int Months = 0, int Days = 0, int Hours = 0)
{
    public const int MaxComponent = 9999;

    public static RetentionDuration Parse(string input)
    {
        var text = input.Trim();
        if (text.Length == 0) throw new RetentionInputException(RetentionInputError.InvalidDuration);
        var values = new Dictionary<char, int>();
        var digits = string.Empty;
        foreach (var character in text)
        {
            if (char.IsAsciiDigit(character))
            {
                digits += character;
                continue;
            }

            if (digits.Length == 0 || !"ymdh".Contains(character) || values.ContainsKey(character))
            {
                throw new RetentionInputException(RetentionInputError.InvalidDuration);
            }

            if (digits.Length > 9 || int.Parse(digits, CultureInfo.InvariantCulture) > MaxComponent) throw new RetentionInputException(RetentionInputError.DurationTooLong);
            values[character] = int.Parse(digits, CultureInfo.InvariantCulture);
            digits = string.Empty;
        }

        if (digits.Length > 0) throw new RetentionInputException(RetentionInputError.InvalidDuration);
        var duration = new RetentionDuration(values.GetValueOrDefault('y'), values.GetValueOrDefault('m'), values.GetValueOrDefault('d'), values.GetValueOrDefault('h'));
        if (duration.IsZero) throw new RetentionInputException(RetentionInputError.ZeroDuration);
        return duration;
    }

    public bool IsZero => Years == 0 && Months == 0 && Days == 0 && Hours == 0;

    public string Text => string.Concat(Parts.Select(part => $"{part.Count}{part.Suffix}"));

    public string Description
    {
        get
        {
            var parts = Parts.Select(part => part.Count == 1 ? part.One : string.Format(CultureInfo.CurrentCulture, part.Many, part.Count)).ToList();
            if (parts.Count == 0) return Strings.Text.RetentionZeroHours;
            return parts.Count == 1 ? parts[0] : string.Format(CultureInfo.CurrentCulture, Strings.Text.RetentionListAnd, string.Join(", ", parts[..^1]), parts[^1]);
        }
    }

    private IEnumerable<(int Count, string Suffix, string One, string Many)> Parts =>
        new[]
        {
            (Years, "y", Strings.Text.RetentionOneYear, Strings.Text.RetentionYears),
            (Months, "m", Strings.Text.RetentionOneMonth, Strings.Text.RetentionMonths),
            (Days, "d", Strings.Text.RetentionOneDay, Strings.Text.RetentionDays),
            (Hours, "h", Strings.Text.RetentionOneHour, Strings.Text.RetentionHours),
        }.Where(part => part.Item1 > 0);

    public bool SurelyCovers(RetentionDuration other)
    {
        var dominates = Years >= other.Years && Months >= other.Months && Days >= other.Days && Hours >= other.Hours;
        var coversCalendarDays = Hours >= other.Hours && FewestCalendarDays >= other.MostCalendarDays;
        return dominates || coversCalendarDays || FewestElapsedHours >= other.MostElapsedHours;
    }

    private int FewestCalendarDays => Years * 365 + Months * 28 + Days;

    private int MostCalendarDays => Years * 366 + Months * 31 + Days;

    // restic steps calendar units back on the wall clock (Go's AddDate), so DST and time zone changes stretch or
    // shrink them in elapsed time; hours are always elapsed time, so only compare the two with a day of slack.
    private int CalendarSlackHours => FewestCalendarDays > 0 ? 24 : 0;

    private int FewestElapsedHours => FewestCalendarDays * 24 - CalendarSlackHours + Hours;

    private int MostElapsedHours => MostCalendarDays * 24 + CalendarSlackHours + Hours;
}

public enum RetentionField
{
    Last,
    Within,
    Hourly,
    Daily,
    Weekly,
    Monthly,
    Yearly,
}

public static class RetentionFields
{
    public static readonly RetentionField[] All = Enum.GetValues<RetentionField>();

    public static string Flag(this RetentionField field) => field switch
    {
        RetentionField.Last => "--keep-last",
        RetentionField.Within => "--keep-within",
        _ => $"--keep-within-{Period(field)}",
    };

    public static string Title(this RetentionField field) => field switch
    {
        RetentionField.Last => Text.RetentionKeepTheLatest,
        RetentionField.Within => Text.RetentionKeepAllWithin,
        _ => field.PeriodTitle(),
    };

    public static string Detail(this RetentionField field) => field switch
    {
        RetentionField.Last => Text.RetentionLastDetail,
        RetentionField.Within => Text.RetentionWithinDetail,
        RetentionField.Hourly => Text.RetentionHourlyDetail,
        RetentionField.Daily => Text.RetentionDailyDetail,
        RetentionField.Weekly => Text.RetentionWeeklyDetail,
        RetentionField.Monthly => Text.RetentionMonthlyDetail,
        _ => Text.RetentionYearlyDetail,
    };

    public static string Placeholder(this RetentionField field) => field switch
    {
        RetentionField.Last => "2",
        RetentionField.Within => "60d",
        RetentionField.Hourly => "2d",
        RetentionField.Daily => "1m",
        RetentionField.Weekly => "6m",
        RetentionField.Monthly => "2y",
        _ => "10y",
    };

    public static string? Period(this RetentionField field) => field switch
    {
        RetentionField.Hourly => "hourly",
        RetentionField.Daily => "daily",
        RetentionField.Weekly => "weekly",
        RetentionField.Monthly => "monthly",
        RetentionField.Yearly => "yearly",
        _ => null,
    };

    public static string PeriodTitle(this RetentionField field) => field switch
    {
        RetentionField.Hourly => Text.RetentionKeepHourlyWithin,
        RetentionField.Daily => Text.RetentionKeepDailyWithin,
        RetentionField.Weekly => Text.RetentionKeepWeeklyWithin,
        RetentionField.Monthly => Text.RetentionKeepMonthlyWithin,
        _ => Text.RetentionKeepYearlyWithin,
    };

    public static string PeriodForFormat(this RetentionField field) => field switch
    {
        RetentionField.Hourly => Text.RetentionHourlyFor,
        RetentionField.Daily => Text.RetentionDailyFor,
        RetentionField.Weekly => Text.RetentionWeeklyFor,
        RetentionField.Monthly => Text.RetentionMonthlyFor,
        _ => Text.RetentionYearlyFor,
    };
}

public sealed record RetentionPolicy
{
    [JsonPropertyName("keepLast")] public int? KeepLast { get; init; }
    [JsonPropertyName("keepWithin")] public string? KeepWithin { get; init; }
    [JsonPropertyName("keepWithinHourly")] public string? KeepWithinHourly { get; init; }
    [JsonPropertyName("keepWithinDaily")] public string? KeepWithinDaily { get; init; }
    [JsonPropertyName("keepWithinWeekly")] public string? KeepWithinWeekly { get; init; }
    [JsonPropertyName("keepWithinMonthly")] public string? KeepWithinMonthly { get; init; }
    [JsonPropertyName("keepWithinYearly")] public string? KeepWithinYearly { get; init; }

    public string? this[RetentionField field] => field switch
    {
        RetentionField.Last => KeepLast?.ToString(CultureInfo.InvariantCulture),
        RetentionField.Within => KeepWithin,
        RetentionField.Hourly => KeepWithinHourly,
        RetentionField.Daily => KeepWithinDaily,
        RetentionField.Weekly => KeepWithinWeekly,
        RetentionField.Monthly => KeepWithinMonthly,
        _ => KeepWithinYearly,
    };

    public RetentionPolicy With(RetentionField field, string value) => field switch
    {
        RetentionField.Last => this with { KeepLast = int.Parse(value, CultureInfo.InvariantCulture) },
        RetentionField.Within => this with { KeepWithin = value },
        RetentionField.Hourly => this with { KeepWithinHourly = value },
        RetentionField.Daily => this with { KeepWithinDaily = value },
        RetentionField.Weekly => this with { KeepWithinWeekly = value },
        RetentionField.Monthly => this with { KeepWithinMonthly = value },
        _ => this with { KeepWithinYearly = value },
    };

    public ValidRetentionPolicy Validated()
    {
        var rules = new List<RetentionRule>();
        if (KeepLast is { } keepLast)
        {
            if (keepLast <= 0) throw new RetentionInputException(RetentionInputError.NotAPositiveNumber);
            if (keepLast > Retention.MaxKeepLast) throw new RetentionInputException(RetentionInputError.NumberTooLarge);
            rules.Add(new RetentionRule(RetentionField.Last, keepLast, null));
        }

        foreach (var field in RetentionFields.All.Where(field => field != RetentionField.Last))
        {
            if (this[field] is { } text)
            {
                rules.Add(new RetentionRule(field, null, RetentionDuration.Parse(text)));
            }
        }

        if (rules.Count == 0) throw new RetentionInputException(RetentionInputError.NoRules);
        return new ValidRetentionPolicy(rules);
    }

    public ValidRetentionPolicy? TryValidated()
    {
        try
        {
            return Validated();
        }
        catch (RetentionInputException)
        {
            return null;
        }
    }
}

public sealed record RetentionRule(RetentionField Field, int? Count, RetentionDuration? Duration)
{
    public string ValueText => Count?.ToString(CultureInfo.InvariantCulture) ?? Duration!.Value.Text;
}

public sealed class ValidRetentionPolicy(IReadOnlyList<RetentionRule> rules)
{
    public IReadOnlyList<RetentionRule> Rules { get; } = rules;

    public RetentionPolicy Policy => Rules.Aggregate(new RetentionPolicy(), (policy, rule) => policy.With(rule.Field, rule.ValueText));

    public ForgetCommand ApplyTo(ForgetCommand forget) => Rules.Aggregate(forget, (command, rule) => rule.Field switch
    {
        RetentionField.Last => command.KeepLast(rule.Count!.Value),
        RetentionField.Within => command.KeepWithin(rule.ValueText),
        RetentionField.Hourly => command.KeepWithinHourly(rule.ValueText),
        RetentionField.Daily => command.KeepWithinDaily(rule.ValueText),
        RetentionField.Weekly => command.KeepWithinWeekly(rule.ValueText),
        RetentionField.Monthly => command.KeepWithinMonthly(rule.ValueText),
        _ => command.KeepWithinYearly(rule.ValueText),
    });

    public string TelemetryValue => string.Join(", ", Rules.Select(rule => $"{rule.Field.Flag()[2..]} {rule.ValueText}"));

    public string Summary
    {
        get
        {
            if (Rules is [{ Count: { } count }]) return count == 1 ? Text.RetentionKeepLatestBackup : string.Format(CultureInfo.CurrentCulture, Text.RetentionKeepLatestBackups, count);
            if (Rules is [{ Field: RetentionField.Within, Duration: { } within }]) return string.Format(CultureInfo.CurrentCulture, Text.RetentionKeepLast, within.Description);
            var sentence = string.Join(", ", Rules.Select(rule => rule switch
            {
                { Count: { } last } => last == 1 ? Text.RetentionLatestBackup : string.Format(CultureInfo.CurrentCulture, Text.RetentionLatestBackups, last),
                { Field: RetentionField.Within } => string.Format(CultureInfo.CurrentCulture, Text.RetentionAllFor, rule.Duration!.Value.Description),
                _ => string.Format(CultureInfo.CurrentCulture, rule.Field.PeriodForFormat(), rule.Duration!.Value.Description),
            }));
            return char.ToUpperInvariant(sentence[0]) + sentence[1..];
        }
    }

    public bool KeepsEverythingKeptBy(ValidRetentionPolicy other) => other.Rules.All(rule => rule switch
    {
        { Count: { } count } => KeepLast is { } keepLast && keepLast >= count,
        _ => new[] { rule.Field, RetentionField.Within }.Any(field => DurationFor(field) is { } duration && duration.SurelyCovers(rule.Duration!.Value)),
    });

    private int? KeepLast => Rules.FirstOrDefault(rule => rule.Count is not null)?.Count;

    private RetentionDuration? DurationFor(RetentionField field) => Rules.FirstOrDefault(rule => rule.Field == field && rule.Duration is not null)?.Duration;
}

[JsonConverter(typeof(SnapshotRetentionConverter))]
public sealed record SnapshotRetention(RetentionPolicy? Policy)
{
    public static readonly SnapshotRetention KeepAll = new((RetentionPolicy?)null);

    public static readonly SnapshotRetention Standard = new(new RetentionPolicy { KeepWithin = "60d" });

    public bool IsKeepAll => Policy is null;

    public ValidRetentionPolicy? PrunablePolicy => Policy?.TryValidated();

    public string Summary => Policy is null
        ? Text.RetentionKeepAllSnapshots
        : Policy.TryValidated()?.Summary ?? Text.RetentionKeepAllUntilCorrected;

    public string TelemetryValue => Policy is null ? "keep-all" : Policy.TryValidated()?.TelemetryValue ?? "invalid";

    public bool MayDeleteMoreThan(SnapshotRetention current)
    {
        if (PrunablePolicy is not { } proposed) return false;
        if (current.PrunablePolicy is not { } existing) return true;
        return !proposed.KeepsEverythingKeptBy(existing);
    }

    public bool MayDeleteResumedSnapshots(IReadOnlyList<string>? hostnames, string host) =>
        MayDeleteMoreThan(KeepAll) && (hostnames?.Contains(host) ?? true);
}

public sealed class SnapshotRetentionConverter : JsonConverter<SnapshotRetention>
{
    public override SnapshotRetention Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        using var document = JsonDocument.ParseValue(ref reader);
        if (document.RootElement.TryGetProperty("keepAll", out var keepAll) && keepAll.ValueKind == JsonValueKind.True) return SnapshotRetention.KeepAll;
        return new SnapshotRetention(document.RootElement.Deserialize<RetentionPolicy>(options)!);
    }

    public override void Write(Utf8JsonWriter writer, SnapshotRetention value, JsonSerializerOptions options)
    {
        if (value.Policy is null)
        {
            writer.WriteStartObject();
            writer.WriteBoolean("keepAll", true);
            writer.WriteEndObject();
            return;
        }

        JsonSerializer.Serialize(writer, value.Policy, options);
    }
}

public enum RetentionPreset
{
    Days15,
    Days30,
    Days60,
    Days90,
    LatestTwo,
    Never,
}

public static class RetentionPresets
{
    public const RetentionPreset Standard = RetentionPreset.Days60;

    public static readonly RetentionPreset[] All = Enum.GetValues<RetentionPreset>();

    public static string Label(this RetentionPreset preset) => preset switch
    {
        RetentionPreset.Days15 => Text.RetentionAfter15Days,
        RetentionPreset.Days30 => Text.RetentionAfter30Days,
        RetentionPreset.Days60 => Text.RetentionAfter60Days,
        RetentionPreset.Days90 => Text.RetentionAfter90Days,
        RetentionPreset.LatestTwo => Text.RetentionKeepLatestTwo,
        _ => Text.RetentionNever,
    };

    public static string KeepLabel(this RetentionPreset preset) => preset switch
    {
        RetentionPreset.Days15 => Text.RetentionKeep15Days,
        RetentionPreset.Days30 => Text.RetentionKeep30Days,
        RetentionPreset.Days60 => Text.RetentionKeep60Days,
        RetentionPreset.Days90 => Text.RetentionKeep90Days,
        RetentionPreset.LatestTwo => Text.RetentionLatestTwoBackups,
        _ => Text.RetentionForever,
    };

    public static SnapshotRetention Retention(this RetentionPreset preset) => preset switch
    {
        RetentionPreset.Days15 => new(new RetentionPolicy { KeepWithin = "15d" }),
        RetentionPreset.Days30 => new(new RetentionPolicy { KeepWithin = "30d" }),
        RetentionPreset.Days60 => new(new RetentionPolicy { KeepWithin = "60d" }),
        RetentionPreset.Days90 => new(new RetentionPolicy { KeepWithin = "90d" }),
        RetentionPreset.LatestTwo => new(new RetentionPolicy { KeepLast = 2 }),
        _ => SnapshotRetention.KeepAll,
    };

    public static RetentionPreset? Matching(SnapshotRetention retention) =>
        All.Cast<RetentionPreset?>().FirstOrDefault(preset => preset!.Value.Retention() == retention);
}

public sealed class RetentionDraft
{
    private readonly Dictionary<RetentionField, string> values;

    public RetentionDraft(RetentionPolicy? policy = null)
    {
        values = RetentionFields.All.ToDictionary(field => field, field => policy?[field] ?? string.Empty);
    }

    public string this[RetentionField field]
    {
        get => values[field];
        set => values[field] = value;
    }

    public Dictionary<RetentionField, RetentionInputError> Errors
    {
        get
        {
            var errors = new Dictionary<RetentionField, RetentionInputError>();
            foreach (var retentionField in RetentionFields.All)
            {
                try
                {
                    Value(retentionField);
                }
                catch (RetentionInputException error)
                {
                    errors[retentionField] = error.Error;
                }
            }

            return errors;
        }
    }

    public RetentionPolicy Policy()
    {
        var policy = new RetentionPolicy();
        foreach (var field in RetentionFields.All)
        {
            if (Value(field) is { } value)
            {
                policy = policy.With(field, value);
            }
        }

        return policy.Validated().Policy;
    }

    private string? Value(RetentionField field)
    {
        var text = values[field].Trim();
        if (text.Length == 0) return null;
        if (field != RetentionField.Last) return RetentionDuration.Parse(text).Text;
        if (!text.All(char.IsAsciiDigit)) throw new RetentionInputException(RetentionInputError.NotAPositiveNumber);
        if (text.Length > 9) throw new RetentionInputException(RetentionInputError.NumberTooLarge);
        var count = int.Parse(text, CultureInfo.InvariantCulture);
        if (count <= 0) throw new RetentionInputException(RetentionInputError.NotAPositiveNumber);
        if (count > Retention.MaxKeepLast) throw new RetentionInputException(RetentionInputError.NumberTooLarge);
        return text.TrimStart('0');
    }
}
