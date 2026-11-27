using System.Text.Json;
using System.Text.Json.Serialization;

using FutoBackups.Core.Strings;

namespace FutoBackups.Core.State;

public sealed class ConfigStore(string filePath)
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    public string FilePath { get; } = filePath;

    public static string StandardDirectory =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "FUTO Backups");

    public static ConfigStore Standard() => new(Path.Combine(StandardDirectory, "config.json"));

    public AppConfig Load(string defaultHost, string home)
    {
        if (!File.Exists(FilePath)) return AppConfig.Defaults(defaultHost, home);
        return JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(FilePath), JsonOptions)
            ?? throw new JsonException(Text.ErrorConfigFileEmpty);
    }

    public string? MoveAside(DateTimeOffset date)
    {
        if (!File.Exists(FilePath)) return null;
        var destination = $"{FilePath}.corrupt-{date.UtcDateTime:yyyy-MM-ddTHHmmssZ}";
        File.Move(FilePath, destination);
        return destination;
    }

    public void Save(AppConfig config)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
        var temporary = FilePath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(config, JsonOptions));
        File.Move(temporary, FilePath, true);
    }
}
