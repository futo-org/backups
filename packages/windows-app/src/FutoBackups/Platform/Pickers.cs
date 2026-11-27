using System.Runtime.InteropServices;

using Microsoft.UI.Xaml;
using Microsoft.Windows.Storage.Pickers;

namespace FutoBackups.Platform;

public static class Pickers
{
    private static readonly Guid DownloadsFolderId = new("374DE290-123F-4565-9164-39C4925E467B");

    public static string? DownloadsFolder
    {
        get
        {
            if (SHGetKnownFolderPath(DownloadsFolderId, 0, 0, out var path) != 0) return null;
            try
            {
                return Marshal.PtrToStringUni(path);
            }
            finally
            {
                Marshal.FreeCoTaskMem(path);
            }
        }
    }

    public static async Task<string?> PickFolderAsync(Window owner, string? commitText = null, string? folder = null)
    {
        var picker = new FolderPicker(owner.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        if (commitText is not null)
        {
            picker.CommitButtonText = commitText;
        }

        if (folder is not null)
        {
            picker.SuggestedFolder = folder;
        }

        var result = await picker.PickSingleFolderAsync();
        return result?.Path;
    }

    public static async Task<string?> PickFileAsync(Window owner)
    {
        var picker = new FileOpenPicker(owner.AppWindow.Id) { SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        var result = await picker.PickSingleFileAsync();
        return result?.Path;
    }

    public static async Task<string?> PickSaveFileAsync(Window owner, string suggestedName, string typeName, string extension)
    {
        var picker = new FileSavePicker(owner.AppWindow.Id) { SuggestedFileName = suggestedName, SuggestedStartLocation = PickerLocationId.DocumentsLibrary };
        picker.FileTypeChoices.Add(typeName, [extension]);
        var result = await picker.PickSaveFileAsync();
        return result?.Path;
    }

    [DllImport("shell32.dll")]
    private static extern int SHGetKnownFolderPath([MarshalAs(UnmanagedType.LPStruct)] Guid id, uint flags, nint token, out nint path);
}
