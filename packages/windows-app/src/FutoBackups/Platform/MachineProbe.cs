using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

using FutoBackups.Core.State;

using Microsoft.Win32;

using Windows.Devices.Enumeration;

namespace FutoBackups.Platform;

public sealed partial class MachineProbe : IDisposable
{
    private const string UsbDeviceInterfaces =
        "System.Devices.InterfaceClassGuid:=\"{A5DCBF10-6530-11D2-901F-00C04FB951ED}\" AND System.Devices.InterfaceEnabled:=System.StructuredQueryType.Boolean#True";
    private const string ContainerIdProperty = "System.Devices.ContainerId";
    private const uint OnlyActivePaths = 0x2;
    private const int PathInfoSize = 72;
    private const int ModeInfoSize = 64;
    private const int OutputTechnologyOffset = 36;
    private static readonly HashSet<uint> InternalOutputs = [6, 11, 13, 0x80000000];

    private readonly Lock gate = new();
    private readonly Dictionary<string, UsbDevice> attached = [];
    private readonly DeviceWatcher watcher;

    public MachineProbe()
    {
        watcher = DeviceInformation.CreateWatcher(UsbDeviceInterfaces, [ContainerIdProperty]);
        watcher.Added += async (_, info) =>
        {
            if (Identify(info.Id) is not { } ids) return;
            var containerName = await ContainerNameAsync(info);
            var name = containerName ?? info.Name;
            lock (gate)
            {
                attached[info.Id] = new UsbDevice(ids.Vendor, ids.Product, name);
            }

            Changed?.Invoke();
        };
        watcher.Updated += (_, _) => { };
        watcher.Removed += (_, update) =>
        {
            bool removed;
            lock (gate)
            {
                removed = attached.Remove(update.Id);
            }

            if (removed)
            {
                Changed?.Invoke();
            }
        };
        watcher.Start();
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.DisplaySettingsChanged += OnDisplaySettingsChanged;
    }

    public event Action? Changed;

    public MachineState Current()
    {
        List<UsbDevice> devices;
        lock (gate)
        {
            devices = attached.Values.DistinctBy(device => (device.VendorId, device.ProductId)).OrderBy(device => device.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        }

        return new MachineState(IsOnPower(), IsOnEthernet(), HasExternalDisplay(), devices);
    }

    public static IDisposable KeepAwake() => new PowerRequest("FUTO Backups is backing up");

    public void Dispose()
    {
        watcher.Stop();
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.DisplaySettingsChanged -= OnDisplaySettingsChanged;
    }

    private void OnNetworkChanged(object? sender, EventArgs e) => Changed?.Invoke();

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e) => Changed?.Invoke();

    private void OnDisplaySettingsChanged(object? sender, EventArgs e) => Changed?.Invoke();

    private static (int Vendor, int Product)? Identify(string interfaceId)
    {
        var match = VendorAndProduct().Match(interfaceId);
        if (!match.Success) return null;
        return (int.Parse(match.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture), int.Parse(match.Groups[2].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture));
    }

    private static async Task<string?> ContainerNameAsync(DeviceInformation info)
    {
        if (!info.Properties.TryGetValue(ContainerIdProperty, out var value) || value is not Guid container) return null;
        try
        {
            var device = await DeviceInformation.CreateFromIdAsync($"{{{container}}}", [], DeviceInformationKind.DeviceContainer);
            return string.IsNullOrWhiteSpace(device.Name) ? null : device.Name;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static bool IsOnPower() => !GetSystemPowerStatus(out var status) || status.AcLineStatus != 0;

    private static bool IsOnEthernet() =>
        NetworkInterface.GetAllNetworkInterfaces().Any(adapter =>
            adapter.OperationalStatus == OperationalStatus.Up
            && adapter.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetT or NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.Ethernet3Megabit
            && adapter.GetIPProperties().GatewayAddresses.Any(gateway => !gateway.Address.Equals(IPAddress.Any) && !gateway.Address.Equals(IPAddress.IPv6Any)));

    private static bool HasExternalDisplay()
    {
        if (GetDisplayConfigBufferSizes(OnlyActivePaths, out var pathCount, out var modeCount) != 0) return false;
        var paths = new byte[pathCount * PathInfoSize];
        var modes = new byte[modeCount * ModeInfoSize];
        if (QueryDisplayConfig(OnlyActivePaths, ref pathCount, paths, ref modeCount, modes, 0) != 0) return false;
        for (var index = 0; index < pathCount; index++)
        {
            var technology = BitConverter.ToUInt32(paths, index * PathInfoSize + OutputTechnologyOffset);
            if (!InternalOutputs.Contains(technology)) return true;
        }

        return false;
    }

    [GeneratedRegex("VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase)]
    private static partial Regex VendorAndProduct();

    [StructLayout(LayoutKind.Sequential)]
    private struct PowerStatus
    {
        public byte AcLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    private static extern bool GetSystemPowerStatus(out PowerStatus status);

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint pathCount, [Out] byte[] paths, ref uint modeCount, [Out] byte[] modes, nint topology);

    private sealed class PowerRequest : IDisposable
    {
        private const int SystemRequired = 1;
        private readonly nint handle;
        private readonly nint reason;

        public PowerRequest(string text)
        {
            reason = Marshal.StringToHGlobalUni(text);
            var context = new ReasonContext { Version = 0, Flags = 1, Reason = reason };
            handle = PowerCreateRequest(ref context);
            if (handle != -1)
            {
                PowerSetRequest(handle, SystemRequired);
            }
        }

        public void Dispose()
        {
            if (handle != -1)
            {
                PowerClearRequest(handle, SystemRequired);
                CloseHandle(handle);
            }

            Marshal.FreeHGlobal(reason);
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ReasonContext
        {
            public uint Version;
            public uint Flags;
            public nint Reason;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern nint PowerCreateRequest(ref ReasonContext context);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool PowerSetRequest(nint request, int type);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool PowerClearRequest(nint request, int type);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(nint handle);
    }
}
