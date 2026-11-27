using FutoBackups.Core.Engine;
using FutoBackups.ViewModels;

using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

using Windows.Foundation;

namespace FutoBackups.Controls;

public sealed partial class UploadSpeedCard : UserControl
{
    public UploadSpeedCard()
    {
        InitializeComponent();
        State.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(StatusViewModel.Speed))
            {
                Draw();
            }
        };
        Chart.SizeChanged += (_, _) => Draw();
    }

    public StatusViewModel State => App.Status;

    private void Draw()
    {
        var points = State.Speed?.Points ?? [];
        var ceiling = State.Speed?.ChartCeiling ?? 1;
        var width = Chart.ActualWidth;
        var height = Chart.ActualHeight;
        var line = new PointCollection();
        var area = new PointCollection();
        if (points.Count > 1 && width > 0)
        {
            area.Add(new Point(X(points[0]), height));
            foreach (var sample in points)
            {
                var point = new Point(X(sample), height - sample.BytesPerSecond / ceiling * height);
                line.Add(point);
                area.Add(point);
            }

            area.Add(new Point(X(points[^1]), height));
        }

        Line.Points = line;
        Area.Points = area;

        double X(UploadSpeedPoint sample) => (UploadSpeed.HistorySeconds - sample.SecondsAgo) / UploadSpeed.HistorySeconds * width;
    }
}
