using System.Globalization;
using System.Text.Json.Serialization;

using FutoBackups.Core.Strings;
using FutoBackups.Core.Util;

namespace FutoBackups.Core.State;

public sealed record UsbDevice(
    [property: JsonPropertyName("vendorId")] int VendorId,
    [property: JsonPropertyName("productId")] int ProductId,
    [property: JsonPropertyName("name")] string Name)
{
    [JsonIgnore] public string ModelCode => $"{VendorId:X4}:{ProductId:X4}";

    public bool IsSameModel(UsbDevice other) => VendorId == other.VendorId && ProductId == other.ProductId;
}

public sealed record MachineState(bool OnPower, bool OnEthernet, bool HasExternalDisplay, IReadOnlyList<UsbDevice> UsbDevices);

public abstract record BackupCondition
{
    public sealed record Power : BackupCondition;

    public sealed record Ethernet : BackupCondition;

    public sealed record ExternalDisplay : BackupCondition;

    public sealed record Usb(UsbDevice Device) : BackupCondition;

    public string Name => this switch
    {
        Power => Text.ConditionPower,
        Ethernet => Text.ConditionEthernet,
        ExternalDisplay => Text.ConditionExternalDisplay,
        Usb usb => usb.Device.Name,
        _ => string.Empty,
    };

    public string TelemetryName => this switch
    {
        Power => "power",
        Ethernet => "ethernet",
        ExternalDisplay => "externalDisplay",
        _ => "usbDevice",
    };

    public bool IsMet(MachineState machine) => this switch
    {
        Power => machine.OnPower,
        Ethernet => machine.OnEthernet,
        ExternalDisplay => machine.HasExternalDisplay,
        Usb usb => machine.UsbDevices.Any(device => device.IsSameModel(usb.Device)),
        _ => true,
    };

    public static string WaitingText(IReadOnlyList<BackupCondition> conditions)
    {
        if (conditions.Count == 0) return string.Empty;
        return string.Format(CultureInfo.CurrentCulture, Text.ConditionWaitingFor, Format.List(conditions.Select(condition => condition.Name).ToList()));
    }
}

public sealed record BackupConditions
{
    public static readonly IReadOnlyList<int> RunAnywayChoices = [1, 2, 3, 5, 7, 14];

    public static readonly BackupConditions None = new();

    [JsonPropertyName("power")] public bool Power { get; init; }
    [JsonPropertyName("ethernet")] public bool Ethernet { get; init; }
    [JsonPropertyName("externalDisplay")] public bool ExternalDisplay { get; init; }
    [JsonPropertyName("usbDevice")] public UsbDevice? UsbDevice { get; init; }
    [JsonPropertyName("runAnywayAfterDays")] public int? RunAnywayAfterDays { get; init; } = 3;

    [JsonIgnore]
    public IReadOnlyList<BackupCondition> Required
    {
        get
        {
            var required = new List<BackupCondition>();
            if (Power)
            {
                required.Add(new BackupCondition.Power());
            }

            if (Ethernet)
            {
                required.Add(new BackupCondition.Ethernet());
            }

            if (ExternalDisplay)
            {
                required.Add(new BackupCondition.ExternalDisplay());
            }

            if (UsbDevice is { } device)
            {
                required.Add(new BackupCondition.Usb(device));
            }

            return required;
        }
    }

    public IReadOnlyList<BackupCondition> Unmet(MachineState machine) => Required.Where(condition => !condition.IsMet(machine)).ToList();
}

public abstract record ScheduledRunDecision
{
    public sealed record NotDue : ScheduledRunDecision;

    public sealed record Run : ScheduledRunDecision;

    public sealed record RunAnyway(IReadOnlyList<BackupCondition> Unmet) : ScheduledRunDecision;

    public sealed record Wait(IReadOnlyList<BackupCondition> Unmet) : ScheduledRunDecision;

    public static ScheduledRunDecision For(AppConfig config, DateTimeOffset now, TimeZoneInfo zone, Func<MachineState> machine)
    {
        if (!config.Schedule.IsDue(config.ScheduleReference, now, zone)) return new NotDue();
        var conditions = config.BackupConditions;
        if (conditions.Required.Count == 0) return new Run();
        var unmet = conditions.Unmet(machine());
        if (unmet.Count == 0) return new Run();
        if (conditions.RunAnywayAfterDays is { } days && (config.WaitingForConditionsSince ?? now).AddDays(days) <= now)
        {
            return new RunAnyway(unmet);
        }

        return new Wait(unmet);
    }
}

public static class UsbDeviceChoices
{
    public static IReadOnlyList<UsbDevice> For(UsbDevice? chosen, IReadOnlyList<UsbDevice> attached)
    {
        if (chosen is null) return attached;
        return attached.Where(device => !device.IsSameModel(chosen)).Append(chosen).OrderBy(device => device.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    public static string Label(UsbDevice device, IReadOnlyList<UsbDevice> choices, IReadOnlyList<UsbDevice> attached)
    {
        var sharesName = choices.Any(other => other.Name == device.Name && !other.IsSameModel(device));
        var name = sharesName ? string.Format(CultureInfo.CurrentCulture, Text.SettingsUsbModel, device.Name, device.ModelCode) : device.Name;
        return attached.Any(other => other.IsSameModel(device)) ? name : string.Format(CultureInfo.CurrentCulture, Text.SettingsUsbNotAttached, name);
    }
}
