using FutoBackups.Core.Engine;
using FutoBackups.Core.Restic;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.Engine;

public class TimeLeftEstimateTests
{
    private const long Total = 10_000_000_000;

    private static BackupProgress Status(long bytesDone, int? resticSecondsRemaining = 1) =>
        new(TotalBytes: Total, BytesDone: bytesDone, SecondsRemaining: resticSecondsRemaining);

    private static int? Upload(TimeLeftEstimate estimate, long bytesPerSecond, double from, double to, long startBytes = 0)
    {
        int? left = null;
        for (var at = from; at <= to; at++)
        {
            left = estimate.SecondsLeft(Status(startBytes + (long)((at - from) * bytesPerSecond)), at);
        }

        return left;
    }

    [Fact]
    public void NothingIsShownWhileResticIsStillScanning()
    {
        var estimate = new TimeLeftEstimate();

        for (var at = 0; at < 60; at++)
        {
            Assert.Null(estimate.SecondsLeft(Status(at * 1_000_000, resticSecondsRemaining: null), at));
        }
    }

    [Fact]
    public void NothingIsShownUntilTheRateHasWarmedUp()
    {
        var estimate = new TimeLeftEstimate();

        Assert.Null(Upload(estimate, 10_000_000, 0, 9));
        Assert.NotNull(Upload(estimate, 10_000_000, 10, 20, startBytes: 100_000_000));
    }

    [Fact]
    public void ASteadyUploadEstimatesTheBytesLeftOverTheRate()
    {
        var estimate = new TimeLeftEstimate();

        var left = Upload(estimate, 10_000_000, 0, 30);

        Assert.InRange(left!.Value, 960, 980);
    }

    [Fact]
    public void ABriefSpikeDoesNotMoveTheShownTime()
    {
        var estimate = new TimeLeftEstimate();
        var before = Upload(estimate, 10_000_000, 0, 120)!.Value;

        var during = Upload(estimate, 100_000_000, 121, 123, startBytes: 1_200_000_000)!.Value;

        Assert.Equal(before - 3, during);
    }

    [Fact]
    public void ALastingSlowdownMovesTheShownTimeLater()
    {
        var estimate = new TimeLeftEstimate();
        var before = Upload(estimate, 10_000_000, 0, 120)!.Value;

        var after = Upload(estimate, 2_000_000, 121, 600, startBytes: 1_200_000_000)!.Value;

        Assert.True(after > before, $"expected more than {before} seconds left, got {after}");
    }

    [Fact]
    public void ARestartedCountStartsTheEstimateAgain()
    {
        var estimate = new TimeLeftEstimate();
        Assert.NotNull(Upload(estimate, 10_000_000, 0, 30));

        Assert.Null(estimate.SecondsLeft(Status(0), 31));
    }
}
