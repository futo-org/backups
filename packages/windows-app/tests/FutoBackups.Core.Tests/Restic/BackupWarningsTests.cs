using FutoBackups.Core.Restic;

namespace FutoBackups.Core.Tests.Restic;

public class BackupWarningsTests
{
    [Fact]
    public void TheCopiedListKeepsWindowsPathsAsTheyAreAndOneWarningPerLine()
    {
        var warnings = new BackupWarnings(
            [
                new BackupWarning(@"C:\Users\Sam\Documents\Mail.pst", "The process cannot access the file because it is being used by another process."),
                new BackupWarning(@"C:\Users\Sam\notes.txt", "Access is denied.\nTry again."),
            ],
            2);

        Assert.Equal(
            @"C:\Users\Sam\Documents\Mail.pst: The process cannot access the file because it is being used by another process." + "\n" +
            @"C:\Users\Sam\notes.txt: Access is denied.\nTry again.",
            warnings.ListText());
    }

    [Fact]
    public void TheHeadlineAndListTitleCountEveryWarning()
    {
        var warnings = new BackupWarnings([new BackupWarning(@"C:\a", "x")], 3);
        Assert.Equal("Could not back up 3 files", warnings.Headline);
        Assert.Equal("Showing the first 1 of 3", warnings.ListTitle);
    }

    [Fact]
    public void ItemErrorsBecomeWarningsWithoutTheRepeatedPath()
    {
        var stderr = """
            {"message_type":"error","error":{"message":"open C:\\Data\\locked.db: the process cannot access the file"},"during":"archival","item":"C:\\Data\\locked.db"}
            {"message_type":"status","percent_done":0.5}
            not json at all
            """;

        var warnings = BackupWarnings.Collect(stderr);

        Assert.Equal([new BackupWarning(@"C:\Data\locked.db", "The process cannot access the file")], warnings.Items);
        Assert.Equal("FUTO Backups could not back up 1 file.", warnings.Summary);
    }

    [Fact]
    public void ChosenFoldersThatAreMissingOrUnreadableAreReportedToo()
    {
        var warnings = BackupWarnings.Collect("D:\\Gone does not exist, skipping\r\nE:\\Locked cannot be accessed, skipping\r\n");

        Assert.Equal([new BackupWarning(@"D:\Gone", "Does not exist"), new BackupWarning(@"E:\Locked", "Cannot be accessed")], warnings.Items);
    }

    [Fact]
    public void AFileSeenWhileScanningKeepsTheReasonFromSavingIt()
    {
        var stderr = """
            {"message_type":"error","error":{"message":"lstat failed"},"during":"scan","item":"C:\\a.txt"}
            {"message_type":"error","error":{"message":"read failed"},"during":"archival","item":"c:\\A.TXT"}
            """;

        var warnings = BackupWarnings.Collect(stderr);

        Assert.Equal(1, warnings.Total);
        Assert.Equal("Read failed", Assert.Single(warnings.Items).Reason);
    }

    [Fact]
    public void BeyondTheLimitWarningsAreCountedButNotListed()
    {
        var stderr = string.Join('\n', Enumerable.Range(1, 5).Select(index => $$"""{"message_type":"error","error":{"message":"denied"},"item":"C:\\f{{index}}"}"""));

        var warnings = BackupWarnings.Collect(stderr, limit: 2);

        Assert.Equal(5, warnings.Total);
        Assert.Equal(2, warnings.Items.Count);
        Assert.True(warnings.IsTruncated);
        Assert.Equal("FUTO Backups could not back up 5 files.", warnings.Summary);
    }

    [Fact]
    public void NoWarningsHaveNoSummary() => Assert.Null(BackupWarnings.Collect(string.Empty).Summary);
}
