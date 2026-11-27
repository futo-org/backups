using FutoBackups.Core.Restic;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Engine;

public sealed class TimeLeftEstimate
{
    private const double RateHalfLifeSeconds = 600;
    private const double WarmUpSeconds = 10;
    private const double CorrectionHalfLifeSeconds = 60;
    private const double DeadbandSeconds = 30;
    private const double DeadbandShare = 0.03;

    private bool scanned;
    private bool sampling;
    private bool moving;
    private double rateBytes;
    private double rateSeconds;
    private long lastBytes;
    private double lastAt;
    private double? shownRemaining;
    private double shownAt;
    private double? end;

    public int? SecondsLeft(BackupProgress progress, double now)
    {
        scanned |= progress.SecondsRemaining is not null;
        if (!scanned)
        {
            return null;
        }

        if (!sampling || progress.BytesDone < lastBytes)
        {
            sampling = true;
            moving = false;
            rateBytes = 0;
            rateSeconds = 0;
            lastBytes = progress.BytesDone;
            lastAt = now;
            shownRemaining = null;
            end = null;
            return null;
        }

        if (moving)
        {
            var decay = Math.Pow(0.5, (now - lastAt) / RateHalfLifeSeconds);
            rateBytes = rateBytes * decay + progress.BytesDone - lastBytes;
            rateSeconds = rateSeconds * decay + now - lastAt;
        }
        else
        {
            moving = progress.BytesDone > lastBytes;
        }

        lastBytes = progress.BytesDone;
        lastAt = now;
        if (rateSeconds < WarmUpSeconds || rateBytes <= 0) return Left(now);

        var remaining = Math.Max(progress.TotalBytes - progress.BytesDone, 0) / (rateBytes / rateSeconds);
        if (shownRemaining is { } previous)
        {
            var elapsed = now - shownAt;
            var counted = previous - elapsed;
            remaining = counted + (remaining - counted) * (1 - Math.Pow(0.5, elapsed / CorrectionHalfLifeSeconds));
        }

        shownRemaining = Math.Max(remaining, 0);
        shownAt = now;
        var candidate = now + shownRemaining.Value;
        var deadband = Math.Max(DeadbandSeconds, shownRemaining.Value * DeadbandShare);
        if (end is not { } held || held <= now || Math.Abs(candidate - held) > deadband)
        {
            end = candidate;
        }

        return Left(now);
    }

    private int? Left(double now) => end is { } held ? (int)Math.Ceiling(Math.Max(held - now, 0)) : null;
}
