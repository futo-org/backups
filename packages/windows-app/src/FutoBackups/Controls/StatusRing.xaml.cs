using FutoBackups.ViewModels;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.Controls;

public sealed partial class StatusRing : UserControl
{
    private const double SmallestWithPercent = 64;

    private double diameter;

    public StatusRing()
    {
        InitializeComponent();
    }

    public StatusViewModel Status => App.Status;

    public double Diameter
    {
        get => diameter;
        set
        {
            diameter = value;
            Root.Width = value;
            Root.Height = value;
            Progress.Width = value;
            Progress.Height = value;
            Busy.Width = value;
            Busy.Height = value;
            Ring.StrokeThickness = Math.Max(2, value / 18);
            StatusIcon.FontSize = value * 0.4;
            BusyIcon.FontSize = value * 0.32;
            Percent.FontSize = value * 0.18;
            Percent.Visibility = value >= SmallestWithPercent ? Visibility.Visible : Visibility.Collapsed;
        }
    }
}
