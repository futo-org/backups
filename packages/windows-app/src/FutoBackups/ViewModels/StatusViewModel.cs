using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core;
using FutoBackups.Core.Engine;
using FutoBackups.Core.Models;
using FutoBackups.Core.State;
using FutoBackups.Core.Status;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace FutoBackups.ViewModels;

public sealed partial class StatusViewModel(AppModel model) : ModelViewModel(model)
{
    private StatusSummary Summary => Model.Status;

    public bool HasError => Model.LastError is not null && Model.Activity is null;

    public string ErrorText => Model.LastError ?? string.Empty;

    [RelayCommand]
    private void DismissError()
    {
        Model.LastError = null;
        Model.ConfigLoadFailure = null;
    }

    [RelayCommand]
    private void BackUpNow() => Model.BackUpNow();

    [RelayCommand]
    private Task SignInAsync() => Model.StartLoginAsync();

    [RelayCommand]
    private void EnterRecoveryKey() => Model.ShowRecoveryKeyStep(new RecoveryKeyStep.ImportKey());

    [RelayCommand]
    private static void AddFolders() => App.Window?.ShowPage("folders");

    [RelayCommand]
    private async Task CancelAsync()
    {
        if (!Model.CanCancelActivity) return;
        var restoring = Model.Activity == ActivityPhase.Restoring;
        var confirmed = await Platform.DialogHost.ConfirmAsync(
            restoring ? Text.OverviewCancelRestoreTitle : Text.OverviewCancelBackupTitle,
            restoring ? Text.OverviewCancelRestoreBody : Text.OverviewCancelBackupBody,
            restoring ? Text.OverviewCancelRestore : Text.OverviewCancelBackup,
            Text.OverviewKeepGoing);
        if (confirmed)
        {
            Model.Cancel();
        }
    }

    [RelayCommand]
    private async Task SignOutAsync()
    {
        var confirmed = await Platform.DialogHost.ConfirmAsync(Text.OverviewSignOutTitle, Text.OverviewSignOutBody, Text.CommonSignOut, Text.CommonCancel);
        if (confirmed)
        {
            Model.Logout();
        }
    }

    public string StatusTitle => Summary.Title;

    public string StatusSubtitle => Summary.Subtitle;

    public string CompactTitle => Model.SignedIn ? Summary.Title : Text.CommonNotSignedIn;

    public string CompactSubtitle => Model.SignedIn ? Summary.Subtitle : Text.TraySignInHint;

    public string StatusGlyph => Icons.For(Summary.Icon);

    public Brush StatusBrush => TintBrush(Summary.Tint);

    public bool IsBusy => Model.Activity is not null;

    public bool HasProgress => Summary.Progress is not null && !Summary.Busy;

    public bool ShowsBusyRing => IsBusy && !HasProgress;

    public bool ShowsStatusRing => !IsBusy;

    public double ProgressPercent => (Summary.Progress ?? 0) * 100;

    public string ProgressText => $"{(int)ProgressPercent}%";

    public string? SidebarProgress => HasProgress ? ProgressText : null;

    public bool HasSidebarProgress => SidebarProgress is not null;

    public bool ShowsBackUpAction => Summary.Action is StatusAction.BackUp or StatusAction.TryAgain;

    public string BackUpActionLabel => Summary.Action == StatusAction.TryAgain ? Text.CommonTryAgain : Text.CommonBackUpNow;

    public bool ShowsAddFoldersAction => Summary.Action == StatusAction.AddFolders;

    public bool ShowsCancelAction => Summary.Action == StatusAction.Cancel && Model.CanCancelActivity;

    public bool ShowsSignInAction => Summary.Action == StatusAction.SignIn;

    public bool ShowsRecoveryKeyAction => Summary.Action == StatusAction.EnterRecoveryKey;

    public bool CanBackUp => Model.CanBackUpNow;

    public bool IsUploading => Model.Activity == ActivityPhase.BackingUp && !Model.IsCancelling;

    public UploadSpeed? Speed => Model.Speed;

    public bool HasUploadStarted => Model.Speed?.HasStarted == true;

    public bool HasNoUploadYet => !HasUploadStarted;

    public string UploadRate => Model.Speed is { } speed ? Format.Rate(speed.BytesPerSecond) : string.Empty;

    public string UploadDetails => Model.Speed?.Details(DateTime.Now) ?? string.Empty;

    public string UploadSummary => Model.Speed?.AccessibilitySummary ?? Text.StatusPreparingUpload;

    public string NextBackup => Model.NextBackupText;

    public string LastBackupText => RunHistory.LastSuccessfulBackup(Model.Config.Runs) is { } finished ? Format.Relative(finished) : Text.StatusNever;

    public string? LastBackupTooltip => Model.Config.LastRun is { } run ? Format.Absolute(run.FinishedAt) : null;

    public bool SignedIn => Model.SignedIn;

    public static Brush TintBrush(StatusTint tint) => (Brush)Application.Current.Resources[tint switch
    {
        StatusTint.Success => "SystemFillColorSuccessBrush",
        StatusTint.Caution => "SystemFillColorCautionBrush",
        StatusTint.Critical => "SystemFillColorCriticalBrush",
        StatusTint.Neutral => "TextFillColorSecondaryBrush",
        _ => "AccentTextFillColorPrimaryBrush",
    }];
}
