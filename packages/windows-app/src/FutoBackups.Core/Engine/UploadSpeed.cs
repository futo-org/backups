using System.Globalization;

using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.Engine;

public sealed record UploadSpeedPoint(double SecondsAgo, double BytesPerSecond);

public sealed record UploadSpeed(
    long UploadedBytes = 0,
    double BytesPerSecond = 0,
    double AverageBytesPerSecond = 0,
    double PeakBytesPerSecond = 0,
    IReadOnlyList<UploadSpeedPoint>? History = null,
    Throttle? Throttle = null)
{
    public const double HistorySeconds = 120;
    private const double MinimumChartCeiling = 100_000;
    private const double ChartHeadroom = 1.15;

    public IReadOnlyList<UploadSpeedPoint> Points => History ?? [];

    public bool HasStarted => UploadedBytes > 0;

    public double ChartCeiling => ChartCeilingFor(Points.Count == 0 ? 0 : Points.Max(point => point.BytesPerSecond));

    internal static double ChartCeilingFor(double highest)
    {
        var target = Math.Max(highest * ChartHeadroom, MinimumChartCeiling);
        var magnitude = Math.Pow(10, Math.Floor(Math.Log10(target)));
        var step = new[] { 1, 2, 2.5, 5, 10 }.FirstOrDefault(candidate => candidate * magnitude >= target, 10);
        return step * magnitude;
    }

    public string Details(DateTime localNow)
    {
        var parts = new List<string> { string.Format(CultureInfo.CurrentCulture, Text.StatusUploadAverage, Format.Rate(AverageBytesPerSecond)) };
        if ((Throttle ?? State.Throttle.Unthrottled).ActiveLimit(localNow) is { } limit)
        {
            parts.Add(string.Format(CultureInfo.CurrentCulture, Text.StatusUploadLimitedTo, Format.Rate(limit)));
        }

        return string.Join(" · ", parts);
    }

    public string AccessibilitySummary => HasStarted
        ? string.Format(CultureInfo.CurrentCulture, Text.StatusUploadSummary, Format.Rate(BytesPerSecond), Format.Rate(AverageBytesPerSecond), Format.Rate(PeakBytesPerSecond))
        : Text.StatusPreparingUpload;
}

public sealed class UploadSpeedMeter(Throttle? throttle = null)
{
    public const double Window = 8;

    private readonly List<(double At, long Total)> samples = [];
    private readonly List<(double At, double BytesPerSecond)> readings = [];
    private long lastReported;
    private long resetOffset;
    private double? uploadStartedAt;

    public UploadSpeed Speed { get; private set; } = new(Throttle: throttle);

    public UploadSpeed Record(long reported, double atSeconds)
    {
        if (samples.Count > 0 && atSeconds <= samples[^1].At) return Speed;
        if (reported < lastReported)
        {
            resetOffset += lastReported;
        }

        lastReported = reported;
        var total = resetOffset + reported;
        if (uploadStartedAt is null && total > 0)
        {
            uploadStartedAt = samples.Count > 0 ? samples[^1].At : atSeconds;
        }

        samples.Add((atSeconds, total));
        while (samples.Count > 1 && atSeconds - samples[1].At >= Window)
        {
            samples.RemoveAt(0);
        }

        var current = CurrentBytesPerSecond(atSeconds);
        readings.Add((atSeconds, current));
        while (readings.Count > 0 && atSeconds - readings[0].At > UploadSpeed.HistorySeconds)
        {
            readings.RemoveAt(0);
        }

        var average = 0.0;
        if (uploadStartedAt is { } started && atSeconds - started > 0)
        {
            average = total / (atSeconds - started);
        }

        Speed = Speed with
        {
            UploadedBytes = total,
            BytesPerSecond = current,
            AverageBytesPerSecond = average,
            PeakBytesPerSecond = Math.Max(Speed.PeakBytesPerSecond, current),
            History = readings.Select(reading => new UploadSpeedPoint(atSeconds - reading.At, reading.BytesPerSecond)).ToList(),
        };
        return Speed;
    }

    // Each interval's bytes are spread evenly over it and weighted by a triangular kernel that falls from 1 now to 0
    // Window seconds ago, so a pack landing in one tick fades out over the window instead of dropping to zero on the
    // next tick, and a stall reaches exactly zero once the window has passed.
    private double CurrentBytesPerSecond(double now)
    {
        var weightedBytes = 0.0;
        var weightedSeconds = 0.0;
        for (var index = 1; index < samples.Count; index++)
        {
            var previous = samples[index - 1];
            var next = samples[index];
            var duration = next.At - previous.At;
            var newestAge = now - next.At;
            var oldestAge = Math.Min(now - previous.At, Window);
            if (duration <= 0 || oldestAge <= newestAge) continue;
            var weight = oldestAge - newestAge - (oldestAge * oldestAge - newestAge * newestAge) / (2 * Window);
            weightedBytes += weight * (next.Total - previous.Total) / duration;
            weightedSeconds += weight;
        }

        return weightedSeconds > 0 ? weightedBytes / weightedSeconds : 0;
    }
}
