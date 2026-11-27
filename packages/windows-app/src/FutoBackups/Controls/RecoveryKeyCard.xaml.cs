using System.ComponentModel;

using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Platform;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Controls;

public sealed partial class RecoveryKeyCard : UserControl, INotifyPropertyChanged
{
    public static readonly DependencyProperty KeyProperty =
        DependencyProperty.Register(nameof(Key), typeof(string), typeof(RecoveryKeyCard), new PropertyMetadata(string.Empty, (card, _) => ((RecoveryKeyCard)card).KeyChanged()));

    private bool copied;
    private bool saved;
    private string? note;

    public RecoveryKeyCard()
    {
        InitializeComponent();
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Key
    {
        get => (string)GetValue(KeyProperty);
        set => SetValue(KeyProperty, value);
    }

    public string KeyLines => string.Join("\n", RepositoryKeys.DisplayLines(Key ?? string.Empty));

    public string CopyGlyph => copied ? Icons.CheckMark : Icons.Copy;

    public string CopyLabel => copied ? Text.CommonCopied : Text.CommonCopy;

    public string SaveGlyph => saved ? Icons.CheckMark : Icons.Download;

    public string SaveLabel => saved ? Text.CommonSaved : Text.CommonSaveToFile;

    public string Note => note ?? string.Empty;

    public bool HasNote => note is not null;

    private string FileText => Text.KeyFileTitle + "\n\n" + string.Join(" ", RepositoryKeys.DisplayLines(Key))
        + "\n\n" + Text.KeyKeepItSafe + "\n";

    private void KeyChanged()
    {
        copied = false;
        saved = false;
        note = null;
        Changed(nameof(KeyLines), nameof(CopyGlyph), nameof(CopyLabel), nameof(SaveGlyph), nameof(SaveLabel), nameof(Note), nameof(HasNote));
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        FileExplorer.Copy(Key);
        copied = true;
        Changed(nameof(CopyGlyph), nameof(CopyLabel));
        Announce((Button)sender, Text.CommonCopied);
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        var path = await Pickers.PickSaveFileAsync(App.Window!, Text.KeyFileName, Text.CommonTextFile, ".txt");
        if (path is null) return;
        try
        {
            await File.WriteAllTextAsync(path, FileText);
        }
        catch (Exception)
        {
            ShowNote(Text.KeyCouldNotSave);
            return;
        }

        ShowNote(null);
        saved = true;
        Changed(nameof(SaveGlyph), nameof(SaveLabel));
        Announce((Button)sender, Text.CommonSaved);
    }

    private async void Print_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await KeyPrinter.PrintAsync(App.Window!, Key, () => ShowNote(Text.KeyCouldNotPrint));
            ShowNote(null);
        }
        catch (Exception)
        {
            ShowNote(Text.KeyCouldNotPrint);
        }
    }

    private static void Announce(Button button, string text) =>
        FrameworkElementAutomationPeer.FromElement(button)?.RaiseNotificationEvent(AutomationNotificationKind.ActionCompleted, AutomationNotificationProcessing.ImportantMostRecent, text, "RecoveryKeyAction");

    private void ShowNote(string? text)
    {
        note = text;
        Changed(nameof(Note), nameof(HasNote));
    }

    private void Changed(params string[] names)
    {
        foreach (var name in names)
        {
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
        }
    }
}
