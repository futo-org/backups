using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.ResticWrapper;

public class ResticOutputTests
{
    [Fact]
    public void AStatusLineBecomesBackupProgress()
    {
        var message = ResticOutput.ParseLine("""{"message_type":"status","percent_done":0.5,"total_files":10,"files_done":5,"total_bytes":2048,"bytes_done":1024,"seconds_remaining":30}""");

        Assert.Equal(new BackupProgress(0.5, 10, 5, 2048, 1024, 30), Assert.IsType<ResticMessage.Status>(message).Progress);
    }

    [Fact]
    public void AnErrorLineNamesTheItemItFailedOn()
    {
        var message = ResticOutput.ParseLine("""{"message_type":"error","error":{"message":"access denied"},"item":"C:\\Data\\locked.db"}""");

        Assert.Equal(@"C:\Data\locked.db: access denied", Assert.IsType<ResticMessage.Error>(message).Message);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("""{"message_type":"verbose_status"}""")]
    [InlineData("""{"message_type":"status""")]
    public void AnythingElseIsIgnored(string line) => Assert.IsType<ResticMessage.Other>(ResticOutput.ParseLine(line));

    [Fact]
    public void TheExitErrorWinsOverEarlierErrors()
    {
        var stderr = """
            {"message_type":"error","error":{"message":"read failed"},"item":"a.txt"}
            {"message_type":"exit_error","code":12,"message":"wrong password or no key found"}
            """;

        Assert.Equal("wrong password or no key found", ResticOutput.LastError(stderr));
    }

    [Fact]
    public void WithoutJsonTheLastLineIsTheError() =>
        Assert.Equal("Fatal: unable to open config file", ResticOutput.LastError("repository not found\nFatal: unable to open config file\n"));

    [Fact]
    public void EmptyStderrHasNoError() => Assert.Null(ResticOutput.LastError("\n  \n"));

    [Fact]
    public void SnapshotTimesWithNanosecondsAreRead()
    {
        var snapshots = ResticOutput.ParseSnapshots("""[{"id":"abc123","short_id":"abc","time":"2026-11-27T10:15:30.123456789+00:00","paths":["C:\\Data"],"hostname":"pc"}]""");

        Assert.Equal(new DateTimeOffset(2026, 11, 27, 10, 15, 30, TimeSpan.Zero).AddTicks(1234567), Assert.Single(snapshots).Time);
    }

    [Fact]
    public void AnUnreadableSnapshotTimeNamesTheSnapshot()
    {
        var error = Assert.Throws<UnreadableSnapshotTimeException>(() => ResticOutput.ParseSnapshots("""[{"id":"abc123","short_id":"abc","time":"yesterday","paths":[],"hostname":"pc"}]"""));

        Assert.Equal("abc", error.ShortId);
    }
    [Fact]
    public void ASummaryLineBecomesTheBackupSummary()
    {
        var message = ResticOutput.ParseLine("""{"message_type":"summary","files_new":2,"files_changed":1,"files_unmodified":7,"data_added":4096,"total_files_processed":10,"total_bytes_processed":8192,"snapshot_id":"abc123"}""");

        Assert.Equal(new BackupSummary(2, 1, 7, 4096, 10, 8192, "abc123"), Assert.IsType<ResticMessage.Summary>(message).Value);
    }

    [Fact]
    public void TheLastItemErrorIgnoresTheExitError()
    {
        var stderr = """
            {"message_type":"error","error":{"message":"access denied"},"item":"C:\\a.db"}
            {"message_type":"exit_error","code":3,"message":"at least one source file could not be read"}
            """;

        Assert.Equal(@"C:\a.db: access denied", ResticOutput.LastItemError(stderr));
    }

    [Fact]
    public void KeysVersionAndStatsAreRead()
    {
        Assert.Equal([new ResticKey("k1", true), new ResticKey("k2", false)], ResticOutput.ParseKeys("""[{"id":"k1","current":true},{"id":"k2","current":false}]"""));
        Assert.Equal("0.19.1", ResticOutput.ParseVersion("""{"message_type":"version","version":"0.19.1","go_version":"go1.25"}"""));
        Assert.Equal(123456, ResticOutput.ParseStatsTotalSize("""{"total_size":123456,"total_file_count":3}"""));
    }

    [Fact]
    public void RestoreStatusAndSummaryLinesBecomeProgress()
    {
        var status = ResticOutput.ParseRestoreLine("""{"message_type":"status","percent_done":0.25,"total_files":4,"files_restored":1,"total_bytes":400,"bytes_restored":100}""");
        var summary = ResticOutput.ParseRestoreLine("""{"message_type":"summary","total_files":4,"files_restored":4}""");

        Assert.Equal((false, new RestoreProgress(0.25, 4, 1, 400, 100)), status);
        Assert.Equal(1, summary!.Value.Progress.PercentDone);
        Assert.True(summary.Value.IsSummary);
        Assert.Null(ResticOutput.ParseRestoreLine("""{"message_type":"verbose_status"}"""));
        Assert.Null(ResticOutput.ParseRestoreLine("Restoring files"));
    }

    [Fact]
    public void ProgressWithoutByteCountsFollowsTheFileCount()
    {
        var progress = new RestoreProgress(PercentDone: 0, TotalFiles: 4, FilesRestored: 1);

        Assert.Equal(0.25, progress.FractionDone);
        Assert.True(progress.HasStarted);
        Assert.False(new RestoreProgress().HasStarted);
    }

    [Fact]
    public void NodeLinesBecomeNodesAndOtherMessagesAreSkipped()
    {
        var nodes = ResticOutput.ParseNodes("""
            {"message_type":"snapshot","id":"abc"}
            {"message_type":"node","name":"a.txt","type":"file","path":"/C/a.txt","size":3,"mtime":"2026-11-27T10:00:00Z"}
            {"message_type":"node","name":"sub","type":"dir","path":"/C/sub"}
            """);

        Assert.Equal(
            [
                new ResticNode("a.txt", "/C/a.txt", ResticNodeKind.File, 3, new DateTimeOffset(2026, 11, 27, 10, 0, 0, TimeSpan.Zero)),
                new ResticNode("sub", "/C/sub", ResticNodeKind.Directory, null, null),
            ],
            nodes);
    }

    [Fact]
    public void ANodeListingThatIsNotJsonNamesTheLine() =>
        Assert.Equal("restic crashed", Assert.Throws<UnreadableResticOutputException>(() => ResticOutput.ParseNodes("restic crashed")).Line);

    [Fact]
    public void ItemProblemsCoverErrorsAndSkippedSources()
    {
        var problems = ResticOutput.ItemProblems("""
            {"message_type":"error","error":{"message":"open C:\\a.db: access denied"},"during":"scan","item":"C:\\a.db"}
            {"message_type":"exit_error","code":3,"message":"incomplete"}
            D:\Gone does not exist, skipping
            E:\Locked cannot be accessed, skipping
            """);

        Assert.Equal(
            [
                new ResticItemProblem(@"C:\a.db", "access denied", ResticProblemKind.Error, DuringScan: true),
                new ResticItemProblem(@"D:\Gone", string.Empty, ResticProblemKind.Missing),
                new ResticItemProblem(@"E:\Locked", string.Empty, ResticProblemKind.Inaccessible),
            ],
            problems);
    }
}
