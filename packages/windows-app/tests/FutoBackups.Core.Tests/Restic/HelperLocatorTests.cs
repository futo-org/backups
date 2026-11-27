using FutoBackups.Core.Restic;

namespace FutoBackups.Core.Tests.Restic;

public sealed class HelperLocatorTests : IDisposable
{
    private readonly string root = Directory.CreateTempSubdirectory("futo-helpers-").FullName;

    public void Dispose() => Directory.Delete(root, true);

    private string Bundle(Helper helper)
    {
        var path = Path.Combine(root, "Helpers", helper.FileName());
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, string.Empty);
        return path;
    }

    [Fact]
    public void AnExistingOverrideWinsOverTheBundledHelper()
    {
        Bundle(Helper.Restic);
        var custom = Path.Combine(root, "custom-restic.exe");
        File.WriteAllText(custom, string.Empty);

        var located = HelperLocator.Locate(Helper.Restic, root, new Dictionary<string, string?> { ["FUTO_BACKUPS_RESTIC"] = custom });

        Assert.Equal(custom, located);
    }

    [Fact]
    public void AnOverrideToAMissingFileFallsBackToTheBundledHelper()
    {
        var bundled = Bundle(Helper.ResticProxy);

        var located = HelperLocator.Locate(Helper.ResticProxy, root, new Dictionary<string, string?> { ["FUTO_BACKUPS_RESTIC_PROXY"] = Path.Combine(root, "gone.exe") });

        Assert.Equal(bundled, located);
    }

    [Fact]
    public void NoHelperAnywhereIsNull() =>
        Assert.Null(HelperLocator.Locate(Helper.Restic, root, new Dictionary<string, string?>()));
}
