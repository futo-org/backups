using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Platform;

public static class DialogHost
{
    private static ContentDialog? open;

    public static event Action? Closed;

    public static bool IsOpen => open is not null;

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        dialog.XamlRoot ??= App.Window?.Content.XamlRoot;
        if (open is not null || dialog.XamlRoot is null) return ContentDialogResult.None;
        open = dialog;
        try
        {
            return await dialog.ShowAsync();
        }
        finally
        {
            open = null;
            Closed?.Invoke();
        }
    }

    public static async Task<bool> ConfirmAsync(string title, string body, string confirm, string cancel)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = body,
            PrimaryButtonText = confirm,
            CloseButtonText = cancel,
            DefaultButton = ContentDialogButton.Close,
        };
        return await ShowAsync(dialog) == ContentDialogResult.Primary;
    }
}
