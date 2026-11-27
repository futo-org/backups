using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Models;
using FutoBackups.Core.Strings;

namespace FutoBackups.ViewModels;

public sealed partial class StartupFailureViewModel(AppModel model) : ModelViewModel(model)
{
    public bool HasFailure => Model.StartupFailure is not null;

    public string Message => Model.StartupFailure ?? string.Empty;

    public bool CanSend => Model.StartupReport is not (StartupReportState.Sending or StartupReportState.Sent);

    public string ReportText => Model.StartupReport switch
    {
        StartupReportState.Sending => Text.StartupReportSending,
        StartupReportState.Sent => Text.StartupReportSent,
        StartupReportState.NeedsSignIn => Text.StartupReportNeedsSignIn,
        StartupReportState.Failed => Text.StartupReportFailed,
        _ => string.Empty,
    };

    public bool HasReportText => ReportText.Length > 0;

    [RelayCommand]
    private Task SendAsync() => Model.SendStartupReportAsync();
}
