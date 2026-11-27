using System.Text.Json;

using FutoBackups.Core.State;

namespace FutoBackups.Core.Tests.State;

public class BackupConditionsTests
{
    private static readonly TimeZoneInfo Paris = TimeZoneInfo.FindSystemTimeZoneById("Europe/Paris");
    private static readonly UsbDevice Dock = new(0x2188, 0x0610, "CalDigit TS4");
    private static readonly UsbDevice Keyboard = new(0x05ac, 0x029c, "Magic Keyboard");
    private static readonly MachineState Desk = new(true, true, true, [Keyboard, Dock]);
    private static readonly MachineState Couch = new(false, false, false, []);

    private static DateTimeOffset Date(int day, int hour = 0)
    {
        var local = new DateTime(2026, 11, day, hour, 0, 0);
        return new DateTimeOffset(local, Paris.GetUtcOffset(local));
    }

    private static AppConfig Config(BackupConditions? conditions, Schedule? schedule = null, DateTimeOffset? lastRun = null, DateTimeOffset? waitingSince = null) =>
        AppConfig.Defaults("test-pc", @"C:\Users\test") with
        {
            Conditions = conditions,
            Schedule = schedule ?? Schedule.Daily(12, 0),
            ScheduleAnchor = lastRun ?? Date(20, 12),
            WaitingForConditionsSince = waitingSince,
        };

    private static ScheduledRunDecision Decide(AppConfig config, DateTimeOffset now, MachineState machine) =>
        ScheduledRunDecision.For(config, now, Paris, () => machine);

    [Fact]
    public void RequiredListsEnabledConditionsInOrder()
    {
        var conditions = new BackupConditions { Power = true, ExternalDisplay = true, UsbDevice = Dock };

        Assert.Equal<BackupCondition>([new BackupCondition.Power(), new BackupCondition.ExternalDisplay(), new BackupCondition.Usb(Dock)], conditions.Required);
        Assert.Empty(BackupConditions.None.Required);
    }

    [Fact]
    public void UnmetListsOnlyMissingConditions()
    {
        var conditions = new BackupConditions { Power = true, Ethernet = true, ExternalDisplay = true, UsbDevice = Dock };

        Assert.Empty(conditions.Unmet(Desk));
        Assert.Equal<BackupCondition>([new BackupCondition.Power(), new BackupCondition.Ethernet(), new BackupCondition.ExternalDisplay(), new BackupCondition.Usb(Dock)], conditions.Unmet(Couch));
        Assert.Equal<BackupCondition>([new BackupCondition.Ethernet(), new BackupCondition.ExternalDisplay()], conditions.Unmet(Couch with { OnPower = true, UsbDevices = [Dock] }));
    }

    [Fact]
    public void ModelCodeIsHexVendorAndProduct()
    {
        Assert.Equal("2188:0610", Dock.ModelCode);
    }

    [Fact]
    public void UsbDeviceMatchesByModelNotName()
    {
        var conditions = new BackupConditions { UsbDevice = Dock };

        Assert.Empty(conditions.Unmet(Couch with { UsbDevices = [Dock with { Name = "TS4 Hub" }] }));
        Assert.Equal<BackupCondition>([new BackupCondition.Usb(Dock)], conditions.Unmet(Couch with { UsbDevices = [Dock with { ProductId = 0x0611 }] }));
    }

    [Fact]
    public void WaitingTextListsTheConditions()
    {
        Assert.Equal(string.Empty, BackupCondition.WaitingText([]));
        Assert.Equal("Waiting for power", BackupCondition.WaitingText([new BackupCondition.Power()]));
        Assert.Equal("Waiting for power and Ethernet", BackupCondition.WaitingText([new BackupCondition.Power(), new BackupCondition.Ethernet()]));
        Assert.Equal(
            "Waiting for Ethernet, an external display and CalDigit TS4",
            BackupCondition.WaitingText([new BackupCondition.Ethernet(), new BackupCondition.ExternalDisplay(), new BackupCondition.Usb(Dock)]));
    }

    [Fact]
    public void NotDueBeforeTheScheduledTime()
    {
        Assert.IsType<ScheduledRunDecision.NotDue>(Decide(Config(new BackupConditions { Power = true }), Date(21, 11), Couch));
    }

    [Fact]
    public void RunsWithoutConditionsWithoutProbingTheMachine()
    {
        var probed = false;

        var decision = ScheduledRunDecision.For(Config(null), Date(21, 12), Paris, () =>
        {
            probed = true;
            return Couch;
        });

        Assert.IsType<ScheduledRunDecision.Run>(decision);
        Assert.False(probed);
    }

    [Fact]
    public void RunsWhenAllConditionsAreMet()
    {
        Assert.IsType<ScheduledRunDecision.Run>(Decide(Config(new BackupConditions { Power = true, Ethernet = true }), Date(21, 12), Desk));
    }

    [Fact]
    public void WaitsWhileAConditionIsUnmet()
    {
        var decision = Decide(Config(new BackupConditions { Power = true, Ethernet = true }), Date(22, 9), Desk with { OnPower = false });

        Assert.Equal<BackupCondition>([new BackupCondition.Power()], Assert.IsType<ScheduledRunDecision.Wait>(decision).Unmet);
    }

    [Fact]
    public void RunsAnywayOnceItHasWaitedLongEnough()
    {
        var waiting = Config(new BackupConditions { Power = true, Ethernet = true, RunAnywayAfterDays = 3 }, waitingSince: Date(21, 12));

        Assert.IsType<ScheduledRunDecision.Wait>(Decide(waiting, Date(24, 11), Couch));
        Assert.Equal<BackupCondition>([new BackupCondition.Power(), new BackupCondition.Ethernet()], Assert.IsType<ScheduledRunDecision.RunAnyway>(Decide(waiting, Date(24, 12), Couch)).Unmet);
    }

    [Theory]
    [InlineData("weekly", 14, 3)]
    [InlineData("daily", 20, 1)]
    [InlineData("hourly", 10, 1)]
    public void TheFirstDueCheckWaitsEvenWhenTheLastBackupIsOlderThanTheDeadline(string kind, int lastRunDay, int days)
    {
        var schedule = kind switch
        {
            "weekly" => Schedule.Weekly(DayOfWeek.Saturday, 12, 0),
            "daily" => Schedule.Daily(12, 0),
            _ => Schedule.Hourly,
        };
        var config = Config(new BackupConditions { Ethernet = true, RunAnywayAfterDays = days }, schedule, Date(lastRunDay, 12));

        Assert.IsType<ScheduledRunDecision.Wait>(Decide(config, Date(21, 12), Couch));
    }

    [Fact]
    public void NeverRunsAnywayWithoutADeadline()
    {
        var config = Config(new BackupConditions { Ethernet = true, RunAnywayAfterDays = null }, waitingSince: Date(21, 12));

        Assert.IsType<ScheduledRunDecision.Wait>(Decide(config, Date(30, 12), Couch));
    }

    [Fact]
    public void NewConditionsRunAnywayAfterThreeDays()
    {
        Assert.Equal(3, new BackupConditions().RunAnywayAfterDays);
    }

    [Fact]
    public void AnOlderConfigKeepsThePcAwakeWithoutConditions()
    {
        var decoded = JsonSerializer.Deserialize<AppConfig>("""{"serverURL":"https://meta.futo.cloud","folders":[],"host":"test-pc"}""")!;

        Assert.True(decoded.KeepsAwake);
        Assert.Equal(BackupConditions.None, decoded.BackupConditions);
    }

    [Fact]
    public void ConditionsRoundTrip()
    {
        var original = Config(new BackupConditions { Power = true, UsbDevice = Dock, RunAnywayAfterDays = null }) with { KeepAwake = false, WaitingForConditionsSince = Date(21, 12) };

        var decoded = JsonSerializer.Deserialize<AppConfig>(JsonSerializer.Serialize(original))!;

        Assert.Equal(original.Conditions, decoded.Conditions);
        Assert.False(decoded.KeepsAwake);
        Assert.Equal(original.WaitingForConditionsSince, decoded.WaitingForConditionsSince);
    }

    [Fact]
    public void AChosenDeviceStaysListedWhenDetachedAndSaysSo()
    {
        var choices = UsbDeviceChoices.For(Dock, [Keyboard]);

        Assert.Equal<UsbDevice>([Dock, Keyboard], choices);
        Assert.Equal("CalDigit TS4 (not attached)", UsbDeviceChoices.Label(Dock, choices, [Keyboard]));
        Assert.Equal("Magic Keyboard", UsbDeviceChoices.Label(Keyboard, choices, [Keyboard]));
    }

    [Fact]
    public void DevicesSharingANameShowTheirModelCode()
    {
        var other = new UsbDevice(0x1234, 0x0001, "CalDigit TS4");
        var choices = UsbDeviceChoices.For(null, [Dock, other]);

        Assert.Equal("CalDigit TS4 (2188:0610)", UsbDeviceChoices.Label(Dock, choices, [Dock, other]));
    }
}
