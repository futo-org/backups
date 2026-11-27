using System.Globalization;

using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core;
using FutoBackups.Core.Api;
using FutoBackups.Core.Engine;
using FutoBackups.Core.Models;
using FutoBackups.Core.Onboarding;
using FutoBackups.Core.State;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;
using FutoBackups.Platform;

using Microsoft.UI.Dispatching;

namespace FutoBackups.ViewModels;

public enum AppStage
{
    Launching,
    TelemetryConsent,
    Welcome,
    RecoveryKey,
    Onboarding,
    Main,
}

public sealed record RepositoryItem(RemoteRepository Repository, bool IsThisPc, StoredKeyCheck? KeyCheck, StoredKeyCheck? EnteredKeyCheck = null)
{
    public string Name => Repository.Name;

    public string Detail => Repository.LastBackup is { } last
        ? $"{Format.Bytes(Repository.SizeBytes)} · {Format.Relative(last)}"
        : $"{Format.Bytes(Repository.SizeBytes)} · {Text.FlowNoBackupsYet}";

    public bool HasStoredKey => KeyCheck == StoredKeyCheck.Opens;

    public string EnteredKeyText => EnteredKeyCheck switch
    {
        StoredKeyCheck.Opens => Text.FlowEnteredKeyOpens,
        StoredKeyCheck.DoesNotOpen => Text.FlowEnteredKeyDoesNotOpen,
        StoredKeyCheck.Checking => Text.FlowEnteredKeyChecking,
        StoredKeyCheck.Unknown => Text.FlowEnteredKeyUnknown,
        _ => string.Empty,
    };

    public bool HasEnteredKeyCheck => EnteredKeyCheck is not null;
}

public sealed record CodeCharacter(string Character)
{
    public bool IsSeparator => Character == "-";

    public bool IsLetter => !IsSeparator;
}

public sealed record StepItem(string Title, int Index, int Current)
{
    public string Number => (Index + 1).ToString(CultureInfo.CurrentCulture);

    public bool ShowsConnector => Index > 0;

    public bool IsReached => Index <= Current;

    public bool IsUpcoming => !IsReached;

    public bool IsDone => Index < Current;

    public bool IsCurrent => Index == Current;

    public bool IsNotCurrent => !IsCurrent;
}

public sealed record ChosenFolder(string Name, string Path, string SizeText);

public sealed partial class BundleChoice(BundleItem bundle) : ObservableObject
{
    public BundleItem Bundle => bundle;

    [ObservableProperty]
    public partial bool IsChosen { get; set; }
}

public sealed partial class FlowViewModel : ModelViewModel
{
    private static readonly WindowsKnownFolders Known = new();

    private readonly Dictionary<string, FolderSize> sizes = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<string> chosenFolders = [];
    private readonly DispatcherQueue dispatcher = DispatcherQueue.GetForCurrentThread();
    private CancellationTokenSource? sizing;
    private string? shownSaveKey;

    public FlowViewModel(AppModel model)
        : base(model)
    {
        Bundles = FolderBundles.All.Select(bundle => new BundleChoice(new BundleItem(bundle, new FolderSelection(Known, bundle).Paths))).ToList();
        ChooseBundle(Bundles[1]);
    }

    public static IReadOnlyList<string> RetentionLabels =>
        [Text.RetentionKeep15Days, Text.RetentionKeep30Days, Text.RetentionKeep60Days, Text.RetentionKeep90Days, Text.RetentionLatestTwoBackups, Text.RetentionForever];

    public AppStage Stage => StageOf(Model);

    public bool IsLaunching => Stage == AppStage.Launching;

    public bool ShowsContent => !IsLaunching;

    public bool IsTelemetryConsent => Stage == AppStage.TelemetryConsent;

    public bool IsWelcome => Stage == AppStage.Welcome;

    public bool ShowsSteps => Stage is AppStage.RecoveryKey or AppStage.Onboarding;

    public bool AllowsServerSelection => Model.AllowsServerSelection;

    public bool IsLoginIdle => Model.Login is LoginState.Idle;

    public bool IsLoginWaiting => Model.Login is LoginState.Waiting;

    public bool IsLoginFinishing => Model.Login is LoginState.Finishing;

    public bool IsLoginFailed => Model.Login is LoginState.Failed;

    public string LoginError => Model.Login is LoginState.Failed failed ? failed.Message : string.Empty;

    public IReadOnlyList<CodeCharacter> Code => Model.Login is LoginState.Waiting waiting
        ? waiting.UserCode.Select(character => new CodeCharacter(character.ToString())).ToList()
        : [];

    public string CodeName => Model.Login is LoginState.Waiting waiting ? string.Format(CultureInfo.CurrentCulture, Text.FlowDeviceCodeName, waiting.UserCode) : Text.FlowDeviceCode;

    private bool InRecovery => Stage == AppStage.RecoveryKey;

    private RecoveryKeyStep? KeyStep => Model.RecoveryKeyStep;

    public bool IsSaveStep => InRecovery && KeyStep is RecoveryKeyStep.Save;

    public bool IsConfirmStep => InRecovery && KeyStep is RecoveryKeyStep.Confirm;

    public bool IsChooseStep => InRecovery && KeyStep is RecoveryKeyStep.ChooseRepository;

    public bool IsEntryStep => InRecovery && KeyStep is RecoveryKeyStep.ImportKey or RecoveryKeyStep.RepositoryKey or RecoveryKeyStep.NewBackupKey;

    [ObservableProperty]
    public partial int OnboardingIndex { get; private set; }

    public bool IsFoldersStep => Stage == AppStage.Onboarding && OnboardingIndex == 0;

    public bool IsReadyStep => Stage == AppStage.Onboarding && OnboardingIndex == 1;

    public bool ShowsStepIndicator => Stage == AppStage.Onboarding || (InRecovery && !Model.IsRecoveringLostKey);

    public IReadOnlyList<StepItem> Steps => Stage == AppStage.Onboarding
        ? StepsFor([Text.CommonFolders, Text.FlowStepReady], OnboardingIndex)
        : StepsFor([Text.FlowSignInTitle, Text.FlowStepSaveKey, Text.CommonConfirm], KeyStep is RecoveryKeyStep.Save ? 1 : 2);

    public string SaveKey => IsSaveStep ? Model.RecoveryKey() ?? string.Empty : string.Empty;

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SaveContinueCommand))]
    public partial bool Saved { get; set; }

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSaveError))]
    public partial string? SaveError { get; private set; }

    public bool HasSaveError => SaveError is not null;

    public string ConfirmDraft
    {
        get;
        set
        {
            if (SetProperty(ref field, value))
            {
                IsConfirmMismatch = false;
                OnPropertyChanged(nameof(ConfirmHint));
            }
        }
    } = string.Empty;

    public string ConfirmHint => KeyHint(ConfirmDraft);

    [ObservableProperty]
    public partial bool IsConfirmMismatch { get; private set; }

    public string EntryTitle => KeyStep switch
    {
        RecoveryKeyStep.RepositoryKey => Text.FlowEnterItsKey,
        RecoveryKeyStep.NewBackupKey => Text.FlowStartNewBackupTitle,
        _ => Text.FlowEnterYourKey,
    };

    public string EntrySubtitle => KeyStep switch
    {
        RecoveryKeyStep.RepositoryKey chosen => string.Format(CultureInfo.CurrentCulture, Text.FlowEnterKeySavedFor, chosen.Repository.Name),
        RecoveryKeyStep.NewBackupKey => Text.FlowNewBackupKeySubtitle,
        _ => Text.ErrorMissingKey,
    };

    public string EntryActionLabel => KeyStep switch
    {
        RecoveryKeyStep.RepositoryKey => Text.FlowContinueThisBackup,
        RecoveryKeyStep.NewBackupKey => Text.FlowStartNewBackup,
        _ => Text.FlowUseThisKey,
    };

    public bool ShowsEntryBack => KeyStep is not RecoveryKeyStep.ImportKey || Model.SignedIn;

    public string EntryDraft
    {
        get;
        set
        {
            if (SetProperty(ref field, value))
            {
                EntryError = null;
                OnPropertyChanged(nameof(EntryHint));
            }
        }
    } = string.Empty;

    public string EntryHint => KeyHint(EntryDraft);

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasEntryError))]
    public partial string? EntryError { get; private set; }

    public bool HasEntryError => EntryError is not null;

    public IReadOnlyList<RepositoryItem> Repositories => KeyStep is RecoveryKeyStep.ChooseRepository choose
        ? choose.Repositories.Select(repository => new RepositoryItem(
            repository,
            string.Equals(repository.Name, Model.Config.Host, StringComparison.OrdinalIgnoreCase),
            Model.StoredKeyChecks.TryGetValue(repository.Id, out var check) ? check : null,
            Model.EnteredKeyChecks.TryGetValue(repository.Id, out var entered) ? entered : null)).OrderByDescending(item => item.IsThisPc).ToList()
        : [];

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasChooseError))]
    public partial string? ChooseError { get; private set; }

    public bool HasChooseError => ChooseError is not null;

    public IReadOnlyList<BundleChoice> Bundles { get; }

    [ObservableProperty]
    public partial IReadOnlyList<ChosenFolder> ChosenFolders { get; private set; } = [];

    [ObservableProperty]
    public partial bool ShowsFolderError { get; private set; }

    public string ChoiceTotal => FolderSizer.TotalText(chosenFolders.Select(SizeOf));

    public string ReadyFolders => chosenFolders.Count == 1 ? Text.FlowOneFolder : string.Format(CultureInfo.CurrentCulture, Text.FlowFolders, chosenFolders.Count);

    public string ReadyFolderList => string.Join(", ", chosenFolders);

    public string ReadySchedule => Model.Config.Schedule.Summary;

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(RetentionEffect))]
    public partial int RetentionIndex { get; set; } = 2;

    private RetentionPreset ChosenRetention => RetentionPresets.All[Math.Max(0, RetentionIndex)];

    public string RetentionEffect => (ChosenRetention.Retention().IsKeepAll ? Text.FlowRetentionKeepsEverything : Text.FlowRetentionDeletesOlder) + " " + Text.FlowRetentionCustomRules;

    [ObservableProperty]
    public partial bool OpenAtLogin { get; set; } = true;

    [ObservableProperty]
    public partial bool CheckForUpdates { get; set; } = true;

    public bool UpdatesAvailable => App.Updater.IsAvailable;

    public static AppStage StageOf(AppModel model)
    {
        if (!model.SessionLoaded) return AppStage.Launching;
        if (model.Config.TelemetryConsentedAt is null) return AppStage.TelemetryConsent;
        if (model.SignedIn && model.RecoveryKeyStep is RecoveryKeyStep.ImportKey) return AppStage.RecoveryKey;
        if (model.SignedIn) return model.NeedsOnboarding ? AppStage.Onboarding : AppStage.Main;
        return model.RecoveryKeyStep is null ? AppStage.Welcome : AppStage.RecoveryKey;
    }

    public static string KeyHint(string input)
    {
        var count = RepositoryKeys.HexDigitCount(input);
        return count == RepositoryKeys.MasterKeyLength ? Text.FlowKeyLooksGood : string.Format(CultureInfo.CurrentCulture, Text.FlowKeyHint, count);
    }

    public bool GoBack()
    {
        if (IsWelcome && IsLoginWaiting)
        {
            Model.CancelLogin();
        }
        else if (IsConfirmStep)
        {
            Model.ShowRecoveryKeyStep(new RecoveryKeyStep.Save());
        }
        else if (IsReadyStep)
        {
            OnboardingIndex = 0;
        }
        else
        {
            return false;
        }

        return true;
    }

    protected override void OnModelChanged()
    {
        var key = IsSaveStep ? Model.RecoveryKey() : null;
        if (key is not null && key != shownSaveKey)
        {
            shownSaveKey = key;
            Saved = false;
            ConfirmDraft = string.Empty;
            EntryDraft = string.Empty;
        }
    }

    partial void OnOnboardingIndexChanged(int value) => NotifyChanges();

    private static List<StepItem> StepsFor(string[] titles, int current) => titles.Select((title, index) => new StepItem(title, index, current)).ToList();

    private FolderSize SizeOf(string path) => sizes.GetValueOrDefault(path) ?? new FolderSize.Calculating();

    private void ShowChoices()
    {
        ChosenFolders = chosenFolders.Select(path => new ChosenFolder(
            string.Equals(path.TrimEnd('\\'), Known.Home.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) ? Text.FlowEntireUserFolder : Path.GetFileName(path.TrimEnd('\\')),
            path,
            SizeOf(path).Text)).ToList();
        NotifyChanges();
    }

    private void MeasureFolders()
    {
        if (chosenFolders.Count > 0)
        {
            ShowsFolderError = false;
        }

        sizing?.Cancel();
        sizing?.Dispose();
        var cancellation = sizing = new CancellationTokenSource();
        var excludes = Model.Config.Excludes;
        foreach (var path in chosenFolders.Where(path => !sizes.ContainsKey(path)).ToList())
        {
            sizes[path] = new FolderSize.Calculating();
            _ = Task.Run(() => FolderSizer.Measure(path, excludes, cancellation.Token), cancellation.Token).ContinueWith(
                task => dispatcher.TryEnqueue(() =>
                {
                    if (task.IsCompletedSuccessfully)
                    {
                        sizes[path] = task.Result;
                        ShowChoices();
                    }
                    else
                    {
                        sizes.Remove(path);
                    }
                }),
                TaskScheduler.Default);
        }

        ShowChoices();
    }

    [RelayCommand]
    private void ConsentContinue() => Model.GrantTelemetryConsent();

    [RelayCommand]
    private static void Quit() => App.Quit();

    [RelayCommand]
    private Task SignInAsync() => Model.StartLoginAsync();

    [RelayCommand]
    private void CancelLogin() => Model.CancelLogin();

    [RelayCommand]
    private void OpenBrowser()
    {
        if (Model.Login is LoginState.Waiting waiting)
        {
            FileExplorer.OpenUrl(waiting.Url);
        }
    }

    [RelayCommand]
    private void CopyCode()
    {
        if (Model.Login is LoginState.Waiting waiting)
        {
            FileExplorer.Copy(waiting.UserCode);
        }
    }

    [RelayCommand(CanExecute = nameof(Saved))]
    private void SaveContinue() => Model.ShowRecoveryKeyStep(new RecoveryKeyStep.Confirm());

    [RelayCommand]
    private async Task ExistingKeyAsync() => SaveError = await Model.ShowExistingBackupsAsync();

    [RelayCommand]
    private void ConfirmKey() => IsConfirmMismatch = !Model.ConfirmRecoveryKey(ConfirmDraft);

    [RelayCommand]
    private void ViewKeyAgain() => Model.ShowRecoveryKeyStep(new RecoveryKeyStep.Save());

    [RelayCommand]
    private async Task EnterKeyAsync()
    {
        if (RepositoryKeys.NormalizedMasterKey(EntryDraft) is null)
        {
            EntryError = Text.FlowEnterKeyError;
            return;
        }

        var error = KeyStep switch
        {
            RecoveryKeyStep.RepositoryKey chosen => await Model.EnterRepositoryKeyAsync(EntryDraft, chosen.Repository),
            RecoveryKeyStep.NewBackupKey => await Model.StartNewBackupWithKeyAsync(EntryDraft),
            _ => await Model.ImportRecoveryKeyAsync(EntryDraft),
        };
        if (error is not null)
        {
            EntryError = error;
            return;
        }

        EntryDraft = string.Empty;
    }

    [RelayCommand]
    private void EntryBack()
    {
        switch (KeyStep)
        {
            case RecoveryKeyStep.RepositoryKey chosen:
                Model.ShowRecoveryKeyStep(new RecoveryKeyStep.ChooseRepository(chosen.Among));
                break;
            case RecoveryKeyStep.NewBackupKey { Repositories.Count: > 0 } fresh:
                Model.ShowRecoveryKeyStep(new RecoveryKeyStep.ChooseRepository(fresh.Repositories));
                break;
            case RecoveryKeyStep.ImportKey:
                Model.DismissRecoveryKeyEntry();
                break;
            default:
                Model.ShowRecoveryKeyStep(new RecoveryKeyStep.Save());
                break;
        }
    }

    [RelayCommand]
    private async Task ChooseRepositoryAsync(RepositoryItem item)
    {
        if (KeyStep is not RecoveryKeyStep.ChooseRepository choose) return;
        ChooseError = null;
        ChooseError = await Model.ChooseRepositoryAsync(item.Repository, choose.Repositories);
    }

    [RelayCommand]
    private async Task StartNewAsync()
    {
        if (KeyStep is not RecoveryKeyStep.ChooseRepository choose) return;
        ChooseError = await Model.StartNewBackupAsync(choose.Repositories);
    }

    [RelayCommand]
    private void ChooseBack() => Model.ShowRecoveryKeyStep(new RecoveryKeyStep.Save());

    [RelayCommand]
    private void ChooseBundle(BundleChoice choice)
    {
        foreach (var bundle in Bundles)
        {
            bundle.IsChosen = ReferenceEquals(bundle, choice);
        }

        chosenFolders.Clear();
        chosenFolders.AddRange(choice.Bundle.Paths);
        MeasureFolders();
    }

    [RelayCommand]
    private async Task ChooseOtherFoldersAsync()
    {
        var path = await Pickers.PickFolderAsync(App.Window!);
        if (path is null || chosenFolders.Contains(path, StringComparer.OrdinalIgnoreCase)) return;
        chosenFolders.Add(path);
        MeasureFolders();
    }

    [RelayCommand]
    private void FoldersContinue()
    {
        ShowsFolderError = chosenFolders.Count == 0;
        if (!ShowsFolderError)
        {
            OnboardingIndex = 1;
        }
    }

    [RelayCommand]
    private void ReadyBack() => OnboardingIndex = 0;

    [RelayCommand]
    private Task FinishNowAsync() => CompleteAsync(true);

    [RelayCommand]
    private Task FinishLaterAsync() => CompleteAsync(false);

    private async Task CompleteAsync(bool backUpNow)
    {
        var retention = ChosenRetention.Retention();
        var hostnames = Model.SnapshotsLoad == SnapshotsLoad.Loaded ? Model.Snapshots.Select(snapshot => snapshot.Hostname).ToList() : null;
        if (retention.MayDeleteResumedSnapshots(hostnames, Model.Config.Host))
        {
            var confirmed = await DialogHost.ConfirmAsync(
                Text.FlowDeleteOldSnapshotsTitle,
                string.Format(CultureInfo.CurrentCulture, Text.FlowDeleteOldSnapshotsBody, retention.Summary),
                Text.SettingsDeleteOldSnapshotsButton,
                Text.CommonCancel);
            if (!confirmed) return;
        }

        sizing?.Cancel();
        if (OpenAtLogin)
        {
            Model.LaunchAtLogin = true;
        }

        if (UpdatesAvailable)
        {
            Model.SetAutomaticUpdateChecks(CheckForUpdates);
        }

        OnboardingIndex = 0;
        Model.FinishOnboarding(chosenFolders.ToList(), ChosenRetention, backUpNow);
    }
}
