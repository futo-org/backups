using FutoBackups.Core.Restic;
using FutoBackups.ResticWrapper;

namespace FutoBackups.Core.Tests.Restic;

public class SnapshotListingTests
{
    [Fact]
    public void RootsAreTheBackedUpFoldersSortedByName()
    {
        var roots = SnapshotListing.Roots([@"C:\Users\Sam\Pictures", @"C:\Users\Sam\Documents"]);
        Assert.Equal(["Documents", "Pictures"], roots.Select(root => root.Name));
        Assert.All(roots, root => Assert.True(root.IsDirectory));
    }

    [Fact]
    public void AListingKeepsOnlyTheFolderItsDirectChildrenFoldersFirstInNaturalOrder()
    {
        var output = """
            {"message_type":"snapshot","id":"abc"}
            {"message_type":"node","name":"Docs","type":"dir","path":"/C/Sam/Docs"}
            {"message_type":"node","name":"file 10.txt","type":"file","path":"/C/Sam/file 10.txt","size":10,"mtime":"2026-11-27T10:00:00.123456789Z"}
            {"message_type":"node","name":"File 2.txt","type":"file","path":"/C/Sam/File 2.txt","size":2}
            {"message_type":"node","name":"inner.txt","type":"file","path":"/C/Sam/Docs/inner.txt"}
            {"message_type":"node","name":"link","type":"symlink","path":"/C/Sam/link"}
            """;

        var entries = SnapshotListing.Parse(output, "/C/Sam");

        Assert.Equal(["Docs", "File 2.txt", "file 10.txt", "link"], entries.Select(entry => entry.Name));
        Assert.Equal([ResticNodeKind.Directory, ResticNodeKind.File, ResticNodeKind.File, ResticNodeKind.Symlink], entries.Select(entry => entry.Kind));
        Assert.Equal(new DateTimeOffset(2026, 11, 27, 10, 0, 0, TimeSpan.Zero).AddTicks(1234567), entries[2].Modified);
        Assert.Equal(10, entries[2].Size);
    }

    [Fact]
    public void AListingThatIsNotJsonCannotBeRead() =>
        Assert.Throws<SnapshotListingException>(() => SnapshotListing.Parse("restic crashed", "/C"));

    [Fact]
    public void ARestoreInPartsNamesThePartAndOnlyAOnePartRestoreShowsAnOverallFraction()
    {
        var started = new RestoreProgress(0.5, 3, 1, 2_000, 1_000);
        var part = new RestoreStep(2, 3, "Pictures", started);
        var whole = new RestoreStep(1, 1, "Documents", started);
        var waiting = new RestoreStep(1, 1, "Documents");

        Assert.Equal("Restoring 2 of 3", part.Title);
        Assert.StartsWith("Pictures · ", part.Subtitle(), StringComparison.Ordinal);
        Assert.Null(part.OverallFraction);
        Assert.Equal("Restoring", whole.Title);
        Assert.Equal(0.5, whole.OverallFraction);
        Assert.Equal("Bringing your files back", waiting.Subtitle());
        Assert.Null(waiting.Fraction);
    }
}
