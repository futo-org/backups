using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.ResticWrapper;

public class ResticCliTests
{
    [Fact]
    public void FlagsKeepTheirOrderAndPathsFollowTheSeparator()
    {
        var invocation = ResticCli.Backup().Host("pc").IExclude("*.iso", "temp").AddFile(@"C:\Data", @"D:\Photos").ToInvocation();

        Assert.Equal(["backup", "--json", "--host", "pc", "--iexclude", "*.iso", "--iexclude", "temp", "--", @"C:\Data", @"D:\Photos"], invocation.Arguments);
    }

    [Fact]
    public void TheRepositoryAndPasswordTravelInTheEnvironmentNotTheArguments()
    {
        var invocation = ResticCli.Snapshots().Repository("rest:https://example/repo").Password("secret").ToInvocation();

        Assert.Equal(["snapshots", "--json"], invocation.Arguments);
        Assert.Equal("rest:https://example/repo", invocation.Environment["RESTIC_REPOSITORY"]);
        Assert.Equal("secret", invocation.Environment["RESTIC_PASSWORD"]);
    }

    [Fact]
    public void UnsetOptionalNumbersAddNoFlag()
    {
        var invocation = ResticCli.Backup().PackSize(null).WalkConcurrency(null).ReadConcurrency(4).ToInvocation();

        Assert.Equal(["backup", "--json", "--read-concurrency", "4"], invocation.Arguments);
    }

    [Fact]
    public void ACommandWithoutPathsHasNoSeparator() =>
        Assert.DoesNotContain("--", ResticCli.Unlock().ToInvocation().Arguments);

    [Fact]
    public void RestoringNamedChildrenMatchesTheirNamesLiterally()
    {
        var invocation = ResticCli.Restore().IncludeLiteral("Holiday [2026].jpg", "*notes?.txt").Snapshot("abc", "/C/Users").ToInvocation();

        Assert.Equal(["restore", "--json", "--include", "/Holiday [[]2026].jpg", "--include", "/[*]notes[?].txt", "--", "abc:/C/Users"], invocation.Arguments);
    }

    [Fact]
    public void ProgressRateAndDiscardedOutputApplyToTheInvocation()
    {
        var invocation = ResticCli.Backup().ProgressFps(2).DiscardStdout().ToInvocation();

        Assert.Equal("2", invocation.Environment["RESTIC_PROGRESS_FPS"]);
        Assert.False(invocation.RetainsStdout);
        Assert.True(ResticCli.Snapshots().ToInvocation().RetainsStdout);
    }

    [Fact]
    public void ForgetPutsEachKeepRuleBeforePrune()
    {
        var invocation = ResticCli.Forget().KeepLast(2).KeepWithinDaily("7d").Prune().ToInvocation();

        Assert.Equal(["forget", "--json", "--keep-last", "2", "--keep-within-daily", "7d", "--prune"], invocation.Arguments);
    }
}
