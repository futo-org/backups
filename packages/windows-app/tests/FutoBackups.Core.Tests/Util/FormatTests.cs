using FutoBackups.Core.Util;

namespace FutoBackups.Core.Tests.Util;

public class FormatTests
{
    private const string Home = @"C:\Users\test";

    private static string Decimal(double value) => value.ToString("0.#", Format.Culture);

    [Fact]
    public void ADateFurtherAwayShowsItsDayAndTime()
    {
        var date = new DateTimeOffset(DateTime.Today.AddDays(5).AddHours(12));

        Assert.Equal($"{date.ToString("ddd d MMM", Format.Culture)}, {Format.Time(date)}", Format.Relative(date));
    }

    [Fact]
    public void NearbyDaysAreNamedAndLowerCasedInsideASentence()
    {
        var noon = new DateTimeOffset(DateTime.Today.AddHours(12));
        var time = Format.Time(noon);

        Assert.Equal($"Today at {time}", Format.Relative(noon));
        Assert.Equal($"tomorrow at {time}", Format.Relative(noon.AddDays(1), inSentence: true));
        Assert.Equal($"Yesterday at {time}", Format.Relative(noon.AddDays(-1)));
    }

    [Fact]
    public void DaysAreTodayYesterdayOrTheirFullDate()
    {
        var older = DateTime.Today.AddDays(-3);

        Assert.Equal("Today", Format.Day(DateTime.Today));
        Assert.Equal("Yesterday", Format.Day(DateTime.Today.AddDays(-1)));
        Assert.Equal(older.ToString("dddd d MMMM", Format.Culture), Format.Day(older));
    }

    [Fact]
    public void ListsJoinTheLastItemWithAnd()
    {
        Assert.Equal(string.Empty, Format.List([]));
        Assert.Equal("power", Format.List(["power"]));
        Assert.Equal("power, Ethernet and a dock", Format.List(["power", "Ethernet", "a dock"]));
    }

    [Theory]
    [InlineData(null, "Zero KB")]
    [InlineData(0L, "Zero KB")]
    [InlineData(1L, "1 byte")]
    [InlineData(999L, "999 bytes")]
    [InlineData(1_400L, "1 KB")]
    [InlineData(250_000_000L, "250 MB")]
    [InlineData(3_000_000_000_000L, "3 TB")]
    public void SizesUseDecimalUnitsWithoutAFractionForKilobytes(long? bytes, string expected) =>
        Assert.Equal(expected, Format.Bytes(bytes));

    [Fact]
    public void SizesBelowAHundredInTheirUnitKeepOneDecimal() =>
        Assert.Equal($"{Decimal(1.5)} MB", Format.Bytes(1_500_000));

    [Fact]
    public void RatesAreInBitsPerSecondWithOneDecimalBelowTen()
    {
        Assert.Equal($"{0.0.ToString("0.0", Format.Culture)} kbit/s", Format.Rate(-5));
        Assert.Equal($"{1.0.ToString("0.0", Format.Culture)} kbit/s", Format.Rate(125));
        Assert.Equal("80 Mbit/s", Format.Rate(10_000_000));
        Assert.Equal($"{2.0.ToString("0.0", Format.Culture)} Gbit/s", Format.Rate(250_000_000));
    }

    [Theory]
    [InlineData(0, "under a minute left")]
    [InlineData(59, "under a minute left")]
    [InlineData(60, "1 min left")]
    [InlineData(3_720, "1 hr, 2 min left")]
    [InlineData(90_000, "25 hr, 0 min left")]
    public void TimeLeftCountsHoursAndMinutes(int seconds, string expected) =>
        Assert.Equal(expected, Format.Duration(seconds));

    [Fact]
    public void CountsPickTheSingularOnlyForOne()
    {
        Assert.Equal("1 file", Format.Count(1, "1 file", "{0} files"));
        Assert.Equal("0 files", Format.Count(0, "1 file", "{0} files"));
        Assert.Equal("3 files", Format.Count(3, "1 file", "{0} files"));
    }

    [Theory]
    [InlineData(@"C:\Users\test", "~")]
    [InlineData(@"C:\Users\test\Documents", @"~\Documents")]
    [InlineData(@"c:\users\TEST\Pictures", @"~\Pictures")]
    [InlineData(@"C:\Users\testing\Documents", @"C:\Users\testing\Documents")]
    [InlineData(@"D:\Data", @"D:\Data")]
    public void PathsInsideTheHomeFolderStartWithATilde(string path, string expected) =>
        Assert.Equal(expected, Format.AbbreviatedPath(path, Home));
}
