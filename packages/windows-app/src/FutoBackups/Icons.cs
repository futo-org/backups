using FutoBackups.Core.Onboarding;
using FutoBackups.Core.Status;

namespace FutoBackups;

public static class Icons
{
    public const string Add = "\uE710";
    public const string Bug = "\uEBE8";
    public const string Calendar = "\uE787";
    public const string Cancel = "\uE711";
    public const string CheckMark = "\uE73E";
    public const string ChevronDown = "\uE70D";
    public const string ChevronLeft = "\uE76B";
    public const string ChevronRight = "\uE76C";
    public const string Cloud = "\uE753";
    public const string Contact = "\uE77B";
    public const string Copy = "\uE8C8";
    public const string Delete = "\uE74D";
    public const string Diagnostic = "\uE9D9";
    public const string Document = "\uE8A5";
    public const string Download = "\uE896";
    public const string Ethernet = "\uE839";
    public const string FileExplorer = "\uEC50";
    public const string Folder = "\uE8B7";
    public const string HardDrive = "\uEDA2";
    public const string Help = "\uE897";
    public const string Hide = "\uED1A";
    public const string History = "\uE81C";
    public const string Home = "\uE80F";
    public const string KeepAwake = "\uEC32";
    public const string Laptop = "\uE7F8";
    public const string Lock = "\uE72E";
    public const string Monitor = "\uE7F4";
    public const string NewFolder = "\uE8F4";
    public const string OpenInNewWindow = "\uE8A7";
    public const string Pattern = "\uE9A9";
    public const string Pause = "\uE769";
    public const string Permissions = "\uE8D7";
    public const string Photo = "\uE91B";
    public const string Play = "\uE768";
    public const string PluggedIn = "\uE83E";
    public const string PowerButton = "\uE7E8";
    public const string Print = "\uE749";
    public const string QuietHours = "\uE708";
    public const string Recent = "\uE823";
    public const string Refresh = "\uE72C";
    public const string Rename = "\uE8AC";
    public const string Search = "\uE721";
    public const string Setting = "\uE713";
    public const string Shield = "\uEA8F";
    public const string Sort = "\uE8CB";
    public const string Speed = "\uEC4A";
    public const string Sync = "\uE895";
    public const string Undo = "\uE7A7";
    public const string Up = "\uE74A";
    public const string Upload = "\uE898";
    public const string Usb = "\uECF0";
    public const string Warning = "\uE7BA";

    public static string For(StatusIcon icon) => icon switch
    {
        StatusIcon.Check => CheckMark,
        StatusIcon.Cross => Cancel,
        StatusIcon.Warning => Warning,
        StatusIcon.Upload => Upload,
        StatusIcon.Download => Download,
        StatusIcon.Search => Search,
        StatusIcon.Pause => Pause,
        StatusIcon.Key => Permissions,
        StatusIcon.Folder => Folder,
        StatusIcon.Delete => Delete,
        _ => Contact,
    };

    public static string For(FolderBundle bundle) => bundle switch
    {
        FolderBundle.Essentials => Document,
        FolderBundle.EssentialsAndMedia => Photo,
        _ => Home,
    };
}
