using System.Globalization;
using System.Reflection;

using CommunityToolkit.Mvvm.ComponentModel;

using FutoBackups.Core.Api;
using FutoBackups.Core.Models;
using FutoBackups.Core.Strings;
using FutoBackups.Core.Updates;

using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

using Velopack;

namespace FutoBackups.Platform;

public sealed partial class Updater : ObservableObject
{
    private static readonly Uri FeedRoot = new("https://github.com/futo-org/backups/releases/download/windows-feed/");

    private static readonly Uri ReleasesRoot = new("https://github.com/futo-org/backups/releases/download/");

    private static readonly TimeSpan BackgroundInterval = TimeSpan.FromHours(24);

    private readonly UpdateManager? manager;
    private readonly AppModel model;
    private DispatcherQueueTimer? timer;

    public Updater(AppModel model)
    {
        this.model = model;
        var candidate = new UpdateManager(new UpdateFeedSource(new HttpClient { Timeout = TimeSpan.FromMinutes(10) }, FeedRoot, ReleasesRoot, ReleasePublicKey()));
        if (candidate.IsInstalled)
        {
            manager = candidate;
        }
    }

    public bool IsAvailable => manager is not null;

    [ObservableProperty] public partial bool IsChecking { get; private set; }

    [ObservableProperty] public partial string? ReadyVersion { get; private set; }

    public void StartBackgroundChecks(DispatcherQueue dispatcher)
    {
        if (manager is null || timer is not null) return;
        timer = dispatcher.CreateTimer();
        timer.Interval = BackgroundInterval;
        timer.Tick += (_, _) => _ = CheckInBackgroundAsync();
        timer.Start();
        _ = CheckInBackgroundAsync();
    }

    public async Task CheckNowAsync(XamlRoot root)
    {
        if (manager is null || IsChecking) return;
        try
        {
            var update = await DownloadAsync(manager);
            if (update is null)
            {
                await ShowAsync(root, Text.UpdatesUpToDateTitle, string.Format(CultureInfo.CurrentCulture, Text.UpdatesUpToDateBody, model.AppVersion), Text.CommonDone, null);
                return;
            }

            await OfferRestartAsync(root, update);
        }
        catch (Exception error) when (error is HttpRequestException or UpdateFeedException or TaskCanceledException or IOException)
        {
            await ShowAsync(root, Text.UpdatesFailedTitle, string.Format(CultureInfo.CurrentCulture, Text.UpdatesFailedBody, error.Message), Text.CommonDone, null);
        }
    }

    private async Task CheckInBackgroundAsync()
    {
        if (manager is null || IsChecking || !model.AllowsBackgroundUpdateChecks) return;
        try
        {
            await DownloadAsync(manager);
        }
        catch (Exception error) when (error is HttpRequestException or UpdateFeedException or TaskCanceledException or IOException)
        {
        }
    }

    private async Task<VelopackAsset?> DownloadAsync(UpdateManager updates)
    {
        IsChecking = true;
        try
        {
            if (updates.UpdatePendingRestart is { } pending)
            {
                ReadyVersion = pending.Version.ToString();
                return pending;
            }

            var info = await updates.CheckForUpdatesAsync();
            if (info is null) return null;
            await updates.DownloadUpdatesAsync(info);
            ReadyVersion = info.TargetFullRelease.Version.ToString();
            return info.TargetFullRelease;
        }
        finally
        {
            IsChecking = false;
        }
    }

    private async Task OfferRestartAsync(XamlRoot root, VelopackAsset update)
    {
        var version = update.Version.ToString();
        if (model.Activity is not null)
        {
            await ShowAsync(root, Text.UpdatesReadyTitle, string.Format(CultureInfo.CurrentCulture, Text.UpdatesReadyDuringBackup, version), Text.CommonDone, null);
            return;
        }

        var restart = await ShowAsync(root, Text.UpdatesReadyTitle, string.Format(CultureInfo.CurrentCulture, Text.UpdatesReadyBody, version), Text.UpdatesLater, Text.UpdatesRestartNow);
        if (restart && model.Activity is null)
        {
            manager!.ApplyUpdatesAndRestart(update);
        }
    }

    private static async Task<bool> ShowAsync(XamlRoot root, string title, string body, string close, string? primary)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = new TextBlock { Text = body, TextWrapping = TextWrapping.Wrap },
            CloseButtonText = close,
            PrimaryButtonText = primary ?? string.Empty,
            DefaultButton = primary is null ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        var result = await DialogHost.ShowAsync(dialog);
        return result == ContentDialogResult.Primary;
    }

    private static string? ReleasePublicKey()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("UpdatePublicKey");
        if (stream is null) return null;
        using var reader = new StreamReader(stream);
        var key = reader.ReadToEnd().Trim();
        return key.Length == 0 ? null : key;
    }
}
