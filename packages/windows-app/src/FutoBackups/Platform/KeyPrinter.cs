using FutoBackups.Core.State;
using FutoBackups.Core.Strings;

using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Printing;

using Windows.Foundation;
using Windows.Graphics.Printing;

namespace FutoBackups.Platform;

public static class KeyPrinter
{
    private static PrintManager? manager;
    private static TypedEventHandler<PrintManager, PrintTaskRequestedEventArgs>? requested;
    private static PrintDocument? document;

    public static async Task PrintAsync(Window owner, string key, Action failed)
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(owner);
        Finish();
        var printing = new PrintDocument();
        var source = printing.DocumentSource;
        var page = Page(key);
        printing.Paginate += (_, _) => printing.SetPreviewPageCount(1, PreviewPageCountType.Final);
        printing.GetPreviewPage += (_, args) => printing.SetPreviewPage(args.PageNumber, page);
        printing.AddPages += (_, _) =>
        {
            printing.AddPage(page);
            printing.AddPagesComplete();
        };

        manager = PrintManagerInterop.GetForWindow(handle);
        document = printing;
        requested = (_, args) =>
        {
            var task = args.Request.CreatePrintTask(Text.KeyFileTitle, request => request.SetSource(source));
            task.Completed += (_, completed) => owner.DispatcherQueue.TryEnqueue(() =>
            {
                Finish();
                if (completed.Completion == PrintTaskCompletion.Failed)
                {
                    failed();
                }
            });
        };
        manager.PrintTaskRequested += requested;
        try
        {
            var shown = await PrintManagerInterop.ShowPrintUIForWindowAsync(handle);
            if (!shown)
            {
                Finish();
            }
        }
        catch
        {
            Finish();
            throw;
        }
    }

    private static void Finish()
    {
        if (manager is not null && requested is not null)
        {
            manager.PrintTaskRequested -= requested;
        }

        manager = null;
        requested = null;
        document = null;
    }

    private static StackPanel Page(string key)
    {
        var black = new SolidColorBrush(Microsoft.UI.Colors.Black);
        var page = new StackPanel { Spacing = 24, Padding = new Thickness(72), Background = new SolidColorBrush(Microsoft.UI.Colors.White) };
        page.Children.Add(new TextBlock { Text = Text.KeyFileTitle, FontSize = 24, FontWeight = FontWeights.SemiBold, Foreground = black });
        page.Children.Add(new TextBlock
        {
            Text = string.Join("\n", RepositoryKeys.DisplayLines(key)),
            FontFamily = new FontFamily("Cascadia Mono, Consolas"),
            FontSize = 20,
            LineHeight = 34,
            Foreground = black,
        });
        page.Children.Add(new TextBlock { Text = Text.KeyKeepItSafe, FontSize = 14, TextWrapping = TextWrapping.Wrap, Foreground = black });
        return page;
    }
}
