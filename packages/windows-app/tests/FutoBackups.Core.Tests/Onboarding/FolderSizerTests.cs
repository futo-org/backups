using FutoBackups.Core.Onboarding;

namespace FutoBackups.Core.Tests.Onboarding;

public class FolderSizerTests
{
    [Fact]
    public void AnExcludedFileIsLeftOutOfTheEstimate()
    {
        var folder = Directory.CreateTempSubdirectory("futo-size-").FullName;
        File.WriteAllBytes(Path.Combine(folder, "photo.jpg"), new byte[10]);
        File.WriteAllBytes(Path.Combine(folder, "Thumbs.db"), new byte[5]);

        var size = FolderSizer.Measure(folder, ["Thumbs.db"], TestContext.Current.CancellationToken);

        Assert.Equal(new FolderSize.Bytes(10), size);
        Directory.Delete(folder, true);
    }
}
