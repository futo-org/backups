using CommunityToolkit.Mvvm.Input;

using FutoBackups.Core.Models;

using Microsoft.UI.Xaml.Controls;

namespace FutoBackups;

public sealed partial class SignInDialog : ContentDialog
{
    public SignInDialog(LoginState.Waiting login)
    {
        Login = login;
        InitializeComponent();
    }

    public LoginState.Waiting Login { get; }

    [RelayCommand]
    private void OpenBrowser() => Platform.FileExplorer.OpenUrl(Login.Url);

    [RelayCommand]
    private void CopyCode() => Platform.FileExplorer.Copy(Login.UserCode);

    private void KeepOpen(ContentDialog sender, ContentDialogButtonClickEventArgs args) => args.Cancel = true;
}
