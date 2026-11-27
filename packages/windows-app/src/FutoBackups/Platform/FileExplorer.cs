using System.Diagnostics;

using Windows.ApplicationModel.DataTransfer;

namespace FutoBackups.Platform;

public static class FileExplorer
{
    public static readonly Uri HelpUrl = new("https://docs.futo.cloud");

    public static readonly Uri SupportUrl = new("https://docs.futo.cloud/help/support");

    public static readonly Uri IssuesUrl = new("https://github.com/futo-org/backups/issues");

    public static void Open(string folder) => Process.Start(new ProcessStartInfo("explorer.exe", $"\"{folder}\"") { UseShellExecute = true });

    public static void Reveal(string path)
    {
        var existing = path;
        while (!Path.Exists(existing) && Path.GetDirectoryName(existing) is { } parent) existing = parent;
        Process.Start(new ProcessStartInfo("explorer.exe", existing == path ? $"/select,\"{path}\"" : $"\"{existing}\"") { UseShellExecute = true });
    }

    public static void OpenUrl(Uri url) => Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });

    public static void Copy(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContentWithOptions(package, new ClipboardContentOptions { IsAllowedInHistory = false, IsRoamable = false });
    }
}
