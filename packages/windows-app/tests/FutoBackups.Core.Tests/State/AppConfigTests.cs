using FutoBackups.Core.State;

namespace FutoBackups.Core.Tests.State;

public class AppConfigTests
{
    private const string Home = @"C:\Users\test";
    private static readonly Uri OtherServer = new("https://backups.example.com/.well-known/yucca.json");
    private static readonly DateTimeOffset Noon = new(2026, 11, 27, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void SwitchingServerRemembersTheRepositoryAndRestoresItOnTheWayBack()
    {
        var run = new RunRecord { StartedAt = Noon, Status = BackupStatus.Complete };
        var original = AppConfig.Defaults("pc", Home) with { RepositoryId = "repo-1", LastRun = run };

        var switched = original.SwitchingServer(OtherServer);
        var back = switched.SwitchingServer(AppConfig.ProductionServerUrl);

        Assert.Null(switched.RepositoryId);
        Assert.Null(switched.LastRun);
        Assert.Equal("repo-1", back.RepositoryId);
        Assert.Equal(run, back.LastRun);
    }

    [Fact]
    public void SwitchingToTheSameServerChangesNothing()
    {
        var config = AppConfig.Defaults("pc", Home) with { RepositoryId = "repo-1" };

        Assert.Same(config, config.SwitchingServer(AppConfig.ProductionServerUrl));
    }

    [Fact]
    public void NewDefaultExcludesAreAddedUnlessTheyWouldExcludeAChosenFolder()
    {
        var temp = $@"{Home}\AppData\Local\Temp";
        var config = AppConfig.Defaults("pc", Home) with { Excludes = [], ExcludeDefaultsVersion = 0, Folders = [temp] };

        var updated = config.AddingNewDefaultExcludes(Home, out var changed);

        Assert.True(changed);
        Assert.Equal(Exclusions.CurrentDefaultsVersion, updated.ExcludeDefaultsVersion);
        Assert.Contains(@"**\node_modules", updated.Excludes);
        Assert.DoesNotContain(temp, updated.Excludes);
    }

    [Fact]
    public void CurrentDefaultExcludesAreLeftAlone()
    {
        var config = AppConfig.Defaults("pc", Home) with { Excludes = [] };

        Assert.Same(config, config.AddingNewDefaultExcludes(Home, out var changed));
        Assert.False(changed);
    }

    [Fact]
    public void TheScheduleCountsFromTheLaterOfTheLastRunAndTheAnchor()
    {
        var config = AppConfig.Defaults("pc", Home) with { LastRun = new RunRecord { StartedAt = Noon }, ScheduleAnchor = Noon.AddHours(2) };

        Assert.Equal(Noon.AddHours(2), config.ScheduleReference);
        Assert.Equal(Noon, (config with { ScheduleAnchor = null }).ScheduleReference);
    }

    [Fact]
    public void CloudOnlyHeadlinesNameFoldersAndSizes()
    {
        Assert.Equal("1 item is stored only in the cloud and was not backed up.", new CloudOnlySkip(1, 0, [@"C:\OneDrive\Photos\"]).Headline);
        Assert.Equal("3 items are stored only in the cloud and were not backed up.", new CloudOnlySkip(3, 0, [@"C:\OneDrive\Photos\"]).Headline);
    }
}
