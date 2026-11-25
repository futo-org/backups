import BackupsCore
import Foundation
import Testing

private var calendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
  return calendar
}

private func date(_ day: Int, hour: Int = 0) -> Date {
  calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
}

private let dock = USBDevice(vendorId: 0x2188, productId: 0x0610, name: "CalDigit TS4")
private let keyboard = USBDevice(vendorId: 0x05ac, productId: 0x029c, name: "Magic Keyboard")

private let desk = MachineState(
  onPower: true, onEthernet: true, hasExternalDisplay: true, usbDevices: [keyboard, dock])
private let couch = MachineState(onPower: false, onEthernet: false, hasExternalDisplay: false, usbDevices: [])

private func config(_ conditions: BackupConditions?, lastRun: Date = date(20, hour: 12)) -> AppConfig {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.conditions = conditions
  config.scheduleAnchor = lastRun
  return config
}

@Test func requiredListsEnabledConditionsInOrder() {
  let conditions = BackupConditions(power: true, ethernet: false, externalDisplay: true, usbDevice: dock)
  #expect(conditions.required == [.power, .externalDisplay, .usbDevice(dock)])
  #expect(BackupConditions.none.required.isEmpty)
}

@Test func unmetListsOnlyMissingConditions() {
  let conditions = BackupConditions(power: true, ethernet: true, externalDisplay: true, usbDevice: dock)
  #expect(conditions.unmet(in: desk).isEmpty)
  #expect(conditions.unmet(in: couch) == [.power, .ethernet, .externalDisplay, .usbDevice(dock)])
  var docked = couch
  docked.onPower = true
  docked.usbDevices = [dock]
  #expect(conditions.unmet(in: docked) == [.ethernet, .externalDisplay])
}

@Test func modelCodeIsHexVendorAndProduct() {
  #expect(dock.modelCode == "2188:0610")
}

@Test func usbDeviceMatchesByModelNotName() {
  let renamed = USBDevice(vendorId: dock.vendorId, productId: dock.productId, name: "TS4 Hub")
  let other = USBDevice(vendorId: dock.vendorId, productId: 0x0611, name: dock.name)
  let conditions = BackupConditions(usbDevice: dock)
  var machine = couch
  machine.usbDevices = [renamed]
  #expect(conditions.unmet(in: machine).isEmpty)
  machine.usbDevices = [other]
  #expect(conditions.unmet(in: machine) == [.usbDevice(dock)])
}

@Test(
  "waitingText",
  arguments: [
    ([BackupCondition](), ""),
    ([BackupCondition.power], "Waiting for power"),
    ([.power, .ethernet], "Waiting for power and Ethernet"),
    ([.ethernet, .externalDisplay, .usbDevice(dock)], "Waiting for Ethernet, an external display and CalDigit TS4"),
  ])
func waitingText(conditions: [BackupCondition], expected: String) {
  #expect(BackupCondition.waitingText(conditions) == expected)
}

@Test func notDueBeforeTheScheduledTime() {
  let decision = config(BackupConditions(power: true)).scheduledRunDecision(
    now: date(21, hour: 11), calendar: calendar, machine: { couch })
  #expect(decision == .notDue)
}

@Test func runsWithoutConditionsWithoutProbingTheMachine() {
  var probed = false
  let decision = config(nil).scheduledRunDecision(now: date(21, hour: 12), calendar: calendar) {
    probed = true
    return couch
  }
  #expect(decision == .run)
  #expect(!probed)
}

@Test func runsWhenAllConditionsAreMet() {
  let decision = config(BackupConditions(power: true, ethernet: true)).scheduledRunDecision(
    now: date(21, hour: 12), calendar: calendar, machine: { desk })
  #expect(decision == .run)
}

@Test func waitsWhileAConditionIsUnmet() {
  var onBattery = desk
  onBattery.onPower = false
  let decision = config(BackupConditions(power: true, ethernet: true)).scheduledRunDecision(
    now: date(22, hour: 9), calendar: calendar, machine: { onBattery })
  #expect(decision == .wait(unmet: [.power]))
}

@Test func runsAnywayOnceTheDeadlinePasses() {
  let conditions = BackupConditions(power: true, ethernet: true, runAnywayAfterDays: 3)
  let stillWaiting = config(conditions).scheduledRunDecision(
    now: date(23, hour: 11), calendar: calendar, machine: { couch })
  #expect(stillWaiting == .wait(unmet: [.power, .ethernet]))
  let overdue = config(conditions).scheduledRunDecision(
    now: date(23, hour: 12), calendar: calendar, machine: { couch })
  #expect(overdue == .runAnyway(unmet: [.power, .ethernet]))
}

@Test func neverRunsAnywayWithoutADeadline() {
  let conditions = BackupConditions(ethernet: true, runAnywayAfterDays: nil)
  let decision = config(conditions).scheduledRunDecision(
    now: date(30, hour: 12), calendar: calendar, machine: { couch })
  #expect(decision == .wait(unmet: [.ethernet]))
}

@Test func newConditionsRunAnywayAfterThreeDays() {
  #expect(BackupConditions().runAnywayAfterDays == 3)
}

@Test func configDefaultsToKeepingAwakeWithoutConditions() throws {
  let json =
    #"{"serverURL":"https://meta.futo.cloud","folders":[],"excludes":[],"schedule":{"kind":"manual"},"throttle":{"bytesPerSec":0,"quietHours":""},"host":"book-pro"}"#
  let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
  #expect(decoded.keepsAwake)
  #expect(decoded.backupConditions == .none)
}

@Test func conditionsRoundTrip() throws {
  var original = config(BackupConditions(power: true, usbDevice: dock, runAnywayAfterDays: nil))
  original.keepAwake = false
  let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(original))
  #expect(decoded.conditions == original.conditions)
  #expect(decoded.keepsAwake == false)
}
