using FutoBackups.Core.State;

namespace FutoBackups.Core.Tests.State;

public class ThrottleTests
{
    [Theory]
    [InlineData("", 0L)]
    [InlineData("   ", 0L)]
    [InlineData("0", 0L)]
    [InlineData("1", 1024L)]
    [InlineData(" 512 ", 524_288L)]
    [InlineData("10000000", 10_240_000_000L)]
    public void UploadLimitParsesKilobytesIntoBytesPerSecond(string text, long expected) => Assert.Equal(expected, UploadLimit.BytesPerSecond(text));

    [Theory]
    [InlineData("-5")]
    [InlineData("1.5")]
    [InlineData("abc")]
    [InlineData("12k")]
    [InlineData("+3")]
    [InlineData("1 000")]
    [InlineData("٣")]
    public void UploadLimitRejectsInputThatIsNotAWholeNumber(string text) =>
        Assert.Equal(UploadLimitError.NotAWholeNumber, Assert.Throws<UploadLimitException>(() => UploadLimit.BytesPerSecond(text)).Error);

    [Theory]
    [InlineData("10000001")]
    [InlineData("9223372036854775807")]
    [InlineData("99999999999999999999999999")]
    public void UploadLimitRejectsValuesAboveTheMaximumWithoutOverflowing(string text) =>
        Assert.Equal(UploadLimitError.TooLarge, Assert.Throws<UploadLimitException>(() => UploadLimit.BytesPerSecond(text)).Error);

    [Fact]
    public void QuietHoursRoundTripAndRejectEqualTimes()
    {
        var quietHours = new QuietHours(new ClockTime(22, 0), new ClockTime(7, 30));
        Assert.Equal("22:00-07:30", quietHours.Text);
        Assert.Equal(quietHours, QuietHours.Parse("22:00-07:30"));
        Assert.Throws<QuietHoursException>(() => new QuietHours(new ClockTime(9, 0), new ClockTime(9, 0)));
        Assert.Null(QuietHours.Parse("09:00-09:00"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("22:00")]
    [InlineData("22:00-")]
    [InlineData("22:00-25:00")]
    [InlineData("x-y")]
    public void QuietHoursParsingRejectsMalformedText(string text) => Assert.Null(QuietHours.Parse(text));

    [Theory]
    [InlineData(0, "", 12, 0, null)]
    [InlineData(2048, "", 12, 0, 2048L)]
    [InlineData(2048, "09:00-17:00", 12, 0, null)]
    [InlineData(2048, "09:00-17:00", 17, 0, 2048L)]
    [InlineData(2048, "09:00-17:00", 8, 59, 2048L)]
    [InlineData(2048, "22:00-06:00", 23, 30, null)]
    [InlineData(2048, "22:00-06:00", 5, 59, null)]
    [InlineData(2048, "22:00-06:00", 6, 0, 2048L)]
    [InlineData(2048, "00:00-00:00", 12, 0, null)]
    [InlineData(2048, "garbage", 12, 0, 2048L)]
    public void TheActiveUploadLimitFollowsTheQuietHours(long bytesPerSec, string quietHours, int hour, int minute, long? expected) =>
        Assert.Equal(expected, new Throttle(bytesPerSec, quietHours).ActiveLimit(new DateTime(2026, 6, 10, hour, minute, 0)));
}
