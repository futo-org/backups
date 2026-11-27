using System.Text.Json;

using FutoBackups.Core.State;

namespace FutoBackups.Core.Tests.State;

public sealed class ConfigStoreTests : IDisposable
{
    private const string Home = @"C:\Users\test";
    private readonly string directory = Path.Combine(Path.GetTempPath(), $"futo-config-{Guid.NewGuid():N}");

    private string FilePath => Path.Combine(directory, "config.json");

    public void Dispose()
    {
        if (Directory.Exists(directory)) Directory.Delete(directory, true);
    }

    [Fact]
    public void AMissingFileLoadsTheDefaults()
    {
        var config = new ConfigStore(FilePath).Load("pc", Home);

        Assert.Equal("pc", config.Host);
        Assert.Equal(Exclusions.Defaults(Home), config.Excludes);
    }

    [Fact]
    public void ASavedConfigLoadsBackTheSame()
    {
        var store = new ConfigStore(FilePath);
        var saved = AppConfig.Defaults("pc", Home) with { RepositoryId = "repo-1", Folders = [@"C:\Data"], Throttle = new Throttle(2048, "22:00-06:00") };

        store.Save(saved);
        var loaded = store.Load("other", Home);

        Assert.Equal("repo-1", loaded.RepositoryId);
        Assert.Equal([@"C:\Data"], loaded.Folders);
        Assert.Equal(saved.Throttle, loaded.Throttle);
        Assert.Equal(saved.Schedule, loaded.Schedule);
        Assert.False(File.Exists(FilePath + ".tmp"));
    }

    [Fact]
    public void AFileHoldingNullFailsToLoad()
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(FilePath, "null");

        Assert.Throws<JsonException>(() => new ConfigStore(FilePath).Load("pc", Home));
    }

    [Fact]
    public void AnUnreadableFileIsMovedAsideWithTheTimeInItsName()
    {
        Directory.CreateDirectory(directory);
        File.WriteAllText(FilePath, "{");

        var moved = new ConfigStore(FilePath).MoveAside(new DateTimeOffset(2026, 11, 27, 10, 15, 30, TimeSpan.Zero));

        Assert.Equal($"{FilePath}.corrupt-2026-11-27T101530Z", moved);
        Assert.Equal("{", File.ReadAllText(moved!));
        Assert.False(File.Exists(FilePath));
    }
}
