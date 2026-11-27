using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Controls;

public sealed partial class PageHeader : UserControl
{
    public static readonly DependencyProperty SubtitleProperty = DependencyProperty.Register(
        nameof(Subtitle), typeof(string), typeof(PageHeader), new PropertyMetadata(string.Empty, OnSubtitleChanged));

    public PageHeader()
    {
        InitializeComponent();
    }

    public string Title { get; set; } = string.Empty;

    public string Subtitle
    {
        get => (string)GetValue(SubtitleProperty);
        set => SetValue(SubtitleProperty, value);
    }

    public object? Actions { get; set; }

    private static void OnSubtitleChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        var header = (PageHeader)sender;
        header.SubtitleText.Text = header.Subtitle;
        header.SubtitleText.Visibility = header.Subtitle.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
}
