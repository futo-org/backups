using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Engine;
using FutoBackups.Core.Models;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;

namespace FutoBackups.ViewModels;

public enum ChangeKeyStep
{
    Explain,
    Save,
    Confirm,
    Applying,
    Done,
    Failed,
}

public sealed partial class ChangeRecoveryKeyViewModel(AppModel model) : ObservableObject
{
    public string NewKey { get; } = RepositoryKeys.GenerateMasterKey();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(Title), nameof(PrimaryText), nameof(SecondaryText), nameof(CloseText), nameof(CanUsePrimary), nameof(IsExplaining), nameof(IsSaving), nameof(IsConfirming), nameof(IsApplying), nameof(IsFinished))]
    public partial ChangeKeyStep Step { get; private set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanUsePrimary))]
    public partial bool Saved { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(CanUsePrimary))]
    public partial string Typed { get; set; } = string.Empty;

    [ObservableProperty]
    public partial bool IsMismatched { get; private set; }

    [ObservableProperty]
    public partial string ResultText { get; private set; } = string.Empty;

    public string? Title => Step switch
    {
        ChangeKeyStep.Explain => Text.SettingsChangeKeyTitle,
        ChangeKeyStep.Save => Text.SettingsChangeKeySaveTitle,
        ChangeKeyStep.Confirm => Text.SettingsChangeKeyConfirmTitle,
        ChangeKeyStep.Done => Text.SettingsChangeKeyChangedTitle,
        ChangeKeyStep.Failed => Text.SettingsChangeKeyFailedTitle,
        _ => null,
    };

    public string PrimaryText => Step switch
    {
        ChangeKeyStep.Explain or ChangeKeyStep.Save => Text.CommonContinue,
        ChangeKeyStep.Confirm => Text.SettingsChangeKeyButton,
        ChangeKeyStep.Done => Text.CommonDone,
        _ => string.Empty,
    };

    public string SecondaryText => Step == ChangeKeyStep.Confirm ? Text.SettingsChangeKeyViewAgain : string.Empty;

    public string CloseText => Step switch
    {
        ChangeKeyStep.Applying or ChangeKeyStep.Done => string.Empty,
        ChangeKeyStep.Failed => Text.CommonClose,
        _ => Text.CommonCancel,
    };

    public bool CanUsePrimary => Step switch
    {
        ChangeKeyStep.Save => Saved,
        ChangeKeyStep.Confirm => Typed.Trim().Length > 0,
        _ => true,
    };

    public bool IsExplaining => Step == ChangeKeyStep.Explain;

    public bool IsSaving => Step == ChangeKeyStep.Save;

    public bool IsConfirming => Step == ChangeKeyStep.Confirm;

    public bool IsApplying => Step == ChangeKeyStep.Applying;

    public bool IsFinished => Step is ChangeKeyStep.Done or ChangeKeyStep.Failed;

    partial void OnTypedChanged(string value) => IsMismatched = false;

    [RelayCommand]
    private async Task PrimaryAsync()
    {
        switch (Step)
        {
            case ChangeKeyStep.Explain:
                Step = ChangeKeyStep.Save;
                break;
            case ChangeKeyStep.Save:
                Step = ChangeKeyStep.Confirm;
                break;
            case ChangeKeyStep.Confirm when !RepositoryKeys.Matches(Typed, NewKey):
                IsMismatched = true;
                break;
            case ChangeKeyStep.Confirm:
                Step = ChangeKeyStep.Applying;
                var result = await model.ChangeRecoveryKeyAsync(NewKey);
                (ResultText, Step) = result switch
                {
                    KeyChange.Changed { Outcome: KeyRotationOutcome.Complete } => (Text.SettingsChangeKeyChangedComplete, ChangeKeyStep.Done),
                    KeyChange.Changed => (Text.SettingsChangeKeyChangedPending, ChangeKeyStep.Done),
                    KeyChange.Failed failed => (failed.Message, ChangeKeyStep.Failed),
                    _ => (string.Empty, ChangeKeyStep.Confirm),
                };
                break;
        }
    }

    [RelayCommand]
    private void ViewAgain() => Step = ChangeKeyStep.Save;
}
