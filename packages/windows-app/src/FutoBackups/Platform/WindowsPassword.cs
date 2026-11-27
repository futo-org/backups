using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

using FutoBackups.Core.Models;
using FutoBackups.Core.Strings;

namespace FutoBackups.Platform;

public static class WindowsPassword
{
    private const int Cancelled = 1223;
    private const int LogonFailure = 1326;
    private const int EnumerateCurrentUser = 0x200;
    private const int InteractiveLogon = 2;
    private const int DefaultProvider = 0;
    private const int Attempts = 3;

    public static OwnerCheck Confirm(nint window, string message)
    {
        var info = new PromptInfo
        {
            Size = Marshal.SizeOf<PromptInfo>(),
            Parent = window,
            Caption = Text.CommonAppName,
            Message = message,
        };
        var error = 0;
        for (var attempt = 0; attempt < Attempts; attempt++)
        {
            var package = 0u;
            var save = false;
            var result = CredUIPromptForWindowsCredentials(ref info, error, ref package, 0, 0, out var buffer, out var size, ref save, EnumerateCurrentUser);
            if (result == Cancelled) return OwnerCheck.Declined;
            if (result != 0) return OwnerCheck.Unavailable;
            try
            {
                var userText = new char[514];
                var domainText = new char[338];
                var passwordText = new char[514];
                var userLength = userText.Length;
                var domainLength = domainText.Length;
                var passwordLength = passwordText.Length;
                if (!CredUnPackAuthenticationBuffer(0, buffer, size, userText, ref userLength, domainText, ref domainLength, passwordText, ref passwordLength)) return OwnerCheck.Unavailable;
                var qualified = Unpacked(userText, userLength);
                var separator = qualified.IndexOf('\\', StringComparison.Ordinal);
                var user = separator < 0 ? qualified : qualified[(separator + 1)..];
                var given = Unpacked(domainText, domainLength);
                var domain = separator >= 0 ? qualified[..separator] : given.Length > 0 ? given : null;
                var password = Unpacked(passwordText, passwordLength);
                Array.Clear(passwordText);
                error = LogonFailure;
                if (!LogonUser(user, domain, password, InteractiveLogon, DefaultProvider, out var token)) continue;
                try
                {
                    using var identity = new WindowsIdentity(token);
                    if (identity.User == WindowsIdentity.GetCurrent().User) return OwnerCheck.Confirmed;
                }
                finally
                {
                    CloseHandle(token);
                }
            }
            finally
            {
                Marshal.Copy(new byte[size], 0, buffer, size);
                Marshal.FreeCoTaskMem(buffer);
            }
        }

        return OwnerCheck.Declined;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PromptInfo
    {
        public int Size;
        public nint Parent;
        public string Message;
        public string Caption;
        public nint Banner;
    }

    [DllImport("credui.dll", EntryPoint = "CredUIPromptForWindowsCredentialsW", CharSet = CharSet.Unicode)]
    private static extern int CredUIPromptForWindowsCredentials(ref PromptInfo info, int authError, ref uint authPackage, nint inBuffer, int inSize, out nint outBuffer, out int outSize, ref bool save, int flags);

    [DllImport("credui.dll", EntryPoint = "CredUnPackAuthenticationBufferW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredUnPackAuthenticationBuffer(int flags, nint buffer, int size, [Out] char[] user, ref int userLength, [Out] char[] domain, ref int domainLength, [Out] char[] password, ref int passwordLength);

    private static string Unpacked(char[] text, int length) => new string(text.AsSpan(0, Math.Clamp(length, 0, text.Length))).TrimEnd('\0');

    [DllImport("advapi32.dll", EntryPoint = "LogonUserW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool LogonUser(string user, string? domain, string password, int logonType, int provider, out nint token);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(nint handle);
}
