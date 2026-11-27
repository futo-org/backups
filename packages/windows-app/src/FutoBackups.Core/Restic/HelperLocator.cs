namespace FutoBackups.Core.Restic;

public enum Helper
{
    Restic,
    ResticProxy,
}

public static class HelperLocator
{
    public static string FileName(this Helper helper) => helper == Helper.Restic ? "restic.exe" : "restic-proxy.exe";

    public static string EnvironmentKey(this Helper helper) => helper == Helper.Restic ? "FUTO_BACKUPS_RESTIC" : "FUTO_BACKUPS_RESTIC_PROXY";

    public static string? Locate(Helper helper, string? baseDirectory = null, IReadOnlyDictionary<string, string?>? environment = null)
    {
        var configured = environment is null ? Environment.GetEnvironmentVariable(helper.EnvironmentKey()) : environment.GetValueOrDefault(helper.EnvironmentKey());
        if (configured is { Length: > 0 } && File.Exists(configured)) return configured;
        var bundled = Path.Combine(baseDirectory ?? AppContext.BaseDirectory, "Helpers", helper.FileName());
        return File.Exists(bundled) ? bundled : null;
    }
}
