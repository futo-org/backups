using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace FutoBackups.Core.State;

public enum SecretKey
{
    AccessToken,
    MasterKey,
    PendingKeyRotation,
}

public interface ISecretStore
{
    string? Get(SecretKey key);

    void Set(SecretKey key, string value);

    void Delete(SecretKey key);
}

public static class SecretKeys
{
    public static string Name(this SecretKey key) => key switch
    {
        SecretKey.AccessToken => "access-token",
        SecretKey.MasterKey => "master-key",
        _ => "pending-key-rotation",
    };
}

public sealed partial class CredentialManagerSecretStore(string service = "FUTO Backups") : ISecretStore
{
    private const int GenericCredential = 1;
    private const int PersistLocalMachine = 2;
    private const int NotFound = 1168;

    public string? Get(SecretKey key)
    {
        if (!CredRead(Target(key), GenericCredential, 0, out var handle))
        {
            var error = Marshal.GetLastPInvokeError();
            if (error == NotFound) return null;
            throw new Win32Exception(error);
        }

        try
        {
            var credential = Marshal.PtrToStructure<Credential>(handle);
            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.UTF8.GetString(bytes);
        }
        finally
        {
            CredFree(handle);
        }
    }

    public void Set(SecretKey key, string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Credential
            {
                Type = GenericCredential,
                TargetName = Target(key),
                CredentialBlobSize = bytes.Length,
                CredentialBlob = blob,
                Persist = PersistLocalMachine,
                UserName = key.Name(),
            };
            if (!CredWrite(ref credential, 0)) throw new Win32Exception(Marshal.GetLastPInvokeError());
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public void Delete(SecretKey key)
    {
        if (CredDelete(Target(key), GenericCredential, 0)) return;
        var error = Marshal.GetLastPInvokeError();
        if (error != NotFound) throw new Win32Exception(error);
    }

    private string Target(SecretKey key) => $"{service}/{key.Name()}";

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, int flags);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, int type, int flags);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern void CredFree(IntPtr buffer);
}

public sealed class InMemorySecretStore(Dictionary<SecretKey, string>? values = null) : ISecretStore
{
    private readonly Dictionary<SecretKey, string> values = values ?? [];
    private readonly Lock gate = new();

    public string? Get(SecretKey key)
    {
        lock (gate)
        {
            return values.GetValueOrDefault(key);
        }
    }

    public void Set(SecretKey key, string value)
    {
        lock (gate)
        {
            values[key] = value;
        }
    }

    public void Delete(SecretKey key)
    {
        lock (gate)
        {
            values.Remove(key);
        }
    }
}
