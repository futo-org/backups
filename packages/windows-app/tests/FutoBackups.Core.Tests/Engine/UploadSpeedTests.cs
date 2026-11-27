using FutoBackups.Core.Engine;

namespace FutoBackups.Core.Tests.Engine;

public class UploadSpeedTests
{
    [Fact]
    public void ASteadyUploadReadsAsItsRate()
    {
        var meter = new UploadSpeedMeter();
        UploadSpeed speed = new();

        for (var second = 0; second <= 20; second++) speed = meter.Record(second * 1_000_000L, second);

        Assert.Equal(1_000_000, speed.BytesPerSecond, 1);
        Assert.Equal(1_000_000, speed.AverageBytesPerSecond, 1);
        Assert.Equal(20_000_000, speed.UploadedBytes);
    }

    [Fact]
    public void AStallFallsToZeroOnceTheWindowHasPassed()
    {
        var meter = new UploadSpeedMeter();
        meter.Record(0, 0);
        meter.Record(4_000_000, 1);

        var during = meter.Record(4_000_000, 4);
        var after = meter.Record(4_000_000, 1 + UploadSpeedMeter.Window);

        Assert.True(during.BytesPerSecond > 0);
        Assert.Equal(0, after.BytesPerSecond);
        Assert.Equal(4_000_000, after.PeakBytesPerSecond, 1);
    }

    [Fact]
    public void ACounterThatStartsAgainKeepsTheTotal()
    {
        var meter = new UploadSpeedMeter();
        meter.Record(5_000_000, 1);

        var speed = meter.Record(1_000_000, 2);

        Assert.Equal(6_000_000, speed.UploadedBytes);
    }

    [Fact]
    public void AnOutOfOrderSampleIsIgnored()
    {
        var meter = new UploadSpeedMeter();
        var first = meter.Record(1_000_000, 2);

        Assert.Same(first, meter.Record(9_000_000, 1));
    }

    [Theory]
    [InlineData(0, 100_000)]
    [InlineData(150_000, 200_000)]
    [InlineData(2_000_000, 2_500_000)]
    [InlineData(4_000_000, 5_000_000)]
    [InlineData(9_000_000, 20_000_000)]
    public void TheChartCeilingLeavesHeadroomAndLandsOnARoundNumber(double highest, double ceiling) =>
        Assert.Equal(ceiling, UploadSpeed.ChartCeilingFor(highest));
}
