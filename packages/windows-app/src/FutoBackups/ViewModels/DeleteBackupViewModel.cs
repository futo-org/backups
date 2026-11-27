using System.Globalization;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Models;
using FutoBackups.Core.Strings;
using FutoBackups.Platform;

namespace FutoBackups.ViewModels;

public sealed partial class DeleteBackupViewModel(AppModel model) : ModelViewModel(model)
{
    private BackupDeletionState State => Model.BackupDeletion;

    public bool IsFinished => Model.IsResetting && State is BackupDeletionState.Idle;

    public string? Title => State switch
    {
        BackupDeletionState.Idle => Text.SettingsDeleteBackupDialogTitle,
        BackupDeletionState.ConfirmingInBrowser => Text.SettingsDeleteBackupConfirmTitle,
        BackupDeletionState.PcStillLinked => Text.SettingsDeleteBackupDeletedTitle,
        BackupDeletionState.Failed => Text.SettingsDeleteBackupFailedTitle,
        _ => null,
    };

    public bool IsIntroducing => State is BackupDeletionState.Idle;

    public string Explanation => string.Format(CultureInfo.CurrentCulture, Text.SettingsDeleteBackupExplain, Model.Config.Host);

    [ObservableProperty]
    public partial bool Understood { get; set; }

    public string? ProgressText => State switch
    {
        BackupDeletionState.Starting => Text.SettingsDeleteBackupOpeningBrowser,
        BackupDeletionState.RemovingThisPc => Text.SettingsDeleteBackupRemovingPc,
        _ => null,
    };

    public bool ShowsProgress => ProgressText is not null;

    public bool IsConfirmingInBrowser => State is BackupDeletionState.ConfirmingInBrowser;

    public string? Message => State switch
    {
        BackupDeletionState.PcStillLinked { OtherRepositories.Count: 0 } => Text.SettingsDeleteBackupStillLinked,
        BackupDeletionState.PcStillLinked => Text.SettingsDeleteBackupOtherBackups,
        BackupDeletionState.Failed failed => failed.Message,
        _ => null,
    };

    public bool HasMessage => Message is not null;

    public IReadOnlyList<string> OtherBackups => State is BackupDeletionState.PcStillLinked linked ? linked.OtherRepositories.Select(repository => repository.Name).ToList() : [];

    public bool HasOtherBackups => OtherBackups.Count > 0;

    public string? Detail => State is BackupDeletionState.PcStillLinked { Detail: { } detail } ? detail : null;

    public bool HasDetail => Detail is not null;

    public string PrimaryText => State switch
    {
        BackupDeletionState.Idle => Text.SettingsDeleteBackupButtonShort,
        BackupDeletionState.PcStillLinked => Text.SettingsDeleteBackupClearAnyway,
        _ => string.Empty,
    };

    public bool CanUsePrimary => State switch
    {
        BackupDeletionState.Idle => Understood,
        BackupDeletionState.PcStillLinked => !Model.IsResetting,
        _ => true,
    };

    public string SecondaryText => State switch
    {
        BackupDeletionState.ConfirmingInBrowser => Text.SettingsDeleteBackupOpenAgain,
        BackupDeletionState.PcStillLinked { OtherRepositories.Count: 0 } or BackupDeletionState.Failed => Text.CommonTryAgain,
        _ => string.Empty,
    };

    public string CloseText => State switch
    {
        BackupDeletionState.RemovingThisPc => string.Empty,
        BackupDeletionState.PcStillLinked or BackupDeletionState.Failed => Text.CommonClose,
        _ => Text.CommonCancel,
    };

    partial void OnUnderstoodChanged(bool value) => NotifyChanges();

    [RelayCommand]
    private async Task PrimaryAsync()
    {
        switch (State)
        {
            case BackupDeletionState.Idle:
                Model.StartBackupDeletion();
                break;
            case BackupDeletionState.PcStillLinked:
                await Model.ResetThisPcAsync();
                break;
        }
    }

    [RelayCommand]
    private void Secondary()
    {
        switch (State)
        {
            case BackupDeletionState.ConfirmingInBrowser confirming:
                FileExplorer.OpenUrl(confirming.Url);
                break;
            case BackupDeletionState.PcStillLinked or BackupDeletionState.Failed:
                Model.DismissBackupDeletion();
                Model.StartBackupDeletion();
                break;
        }
    }

    public void Close()
    {
        Model.CancelBackupDeletion();
        Model.DismissBackupDeletion();
    }
}
