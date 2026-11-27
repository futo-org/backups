using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Models;
using FutoBackups.Core.State;

namespace FutoBackups.ViewModels;

public sealed partial class ServerEditorViewModel(AppModel model) : ObservableObject
{
    public string Draft
    {
        get;
        set
        {
            if (SetProperty(ref field, value))
            {
                IsInvalid = false;
            }
        }
    } = model.Config.ServerUrl.AbsoluteUri;

    [ObservableProperty]
    public partial bool IsInvalid { get; private set; }

    [RelayCommand]
    private void UseProduction() => Use(AppConfig.ProductionServerUrl);

    [RelayCommand]
    private void UseLocalDevelopment() => Use(AppConfig.DevServerUrl);

    [RelayCommand]
    private void Apply()
    {
        if (!Uri.TryCreate(Draft.Trim(), UriKind.Absolute, out var url) || url.Scheme is not ("http" or "https") || url.Host.Length == 0)
        {
            IsInvalid = true;
            return;
        }

        model.SetServerUrl(url);
    }

    private void Use(Uri url)
    {
        Draft = url.AbsoluteUri;
        model.SetServerUrl(url);
    }
}
