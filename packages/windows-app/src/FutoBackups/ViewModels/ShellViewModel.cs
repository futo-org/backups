using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Models;
using FutoBackups.Core.Status;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups.ViewModels;

public sealed partial class ShellViewModel : ModelViewModel
{
    public ShellViewModel(AppModel model)
        : base(model)
    {
        OnModelChanged();
    }

    public bool IsInFlow => FlowViewModel.StageOf(Model) != AppStage.Main;

    public bool IsInMain => !IsInFlow;

    public LoginState.Waiting? WaitingLogin => Model.SignedIn && Model.Login is LoginState.Waiting waiting ? waiting : null;

    [ObservableProperty]
    public partial string CompletionTitle { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial string CompletionMessage { get; private set; } = string.Empty;

    [ObservableProperty]
    public partial InfoBarSeverity CompletionSeverity { get; private set; }

    [ObservableProperty]
    public partial bool IsCompletionOpen { get; set; }

    protected override void OnModelChanged()
    {
        if (Model.Completion is { } completion)
        {
            CompletionTitle = completion.Title;
            CompletionMessage = completion.Message;
            CompletionSeverity = completion.Tint switch
            {
                StatusTint.Critical => InfoBarSeverity.Error,
                StatusTint.Caution => InfoBarSeverity.Warning,
                StatusTint.Success => InfoBarSeverity.Success,
                _ => InfoBarSeverity.Informational,
            };
            IsCompletionOpen = true;
            Model.Completion = null;
        }

        if (Model.Activity is not null)
        {
            IsCompletionOpen = false;
        }
    }

    [RelayCommand]
    private void CancelLogin()
    {
        if (Model.Login is LoginState.Waiting)
        {
            Model.CancelLogin();
        }
    }
}
