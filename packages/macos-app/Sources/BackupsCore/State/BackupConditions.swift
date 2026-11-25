import Foundation

public struct USBDevice: Codable, Equatable, Hashable, Sendable {
  public var vendorId: Int
  public var productId: Int
  public var name: String

  public init(vendorId: Int, productId: Int, name: String) {
    self.vendorId = vendorId
    self.productId = productId
    self.name = name
  }

  public var modelCode: String {
    String(format: "%04X:%04X", vendorId, productId)
  }

  public func isSameModel(as other: USBDevice) -> Bool {
    vendorId == other.vendorId && productId == other.productId
  }
}

public struct MachineState: Equatable, Sendable {
  public var onPower: Bool
  public var onEthernet: Bool
  public var hasExternalDisplay: Bool
  public var usbDevices: [USBDevice]

  public init(onPower: Bool, onEthernet: Bool, hasExternalDisplay: Bool, usbDevices: [USBDevice]) {
    self.onPower = onPower
    self.onEthernet = onEthernet
    self.hasExternalDisplay = hasExternalDisplay
    self.usbDevices = usbDevices
  }
}

public enum BackupCondition: Equatable, Hashable, Sendable {
  case power
  case ethernet
  case externalDisplay
  case usbDevice(USBDevice)

  public var name: String {
    switch self {
    case .power: "power"
    case .ethernet: "Ethernet"
    case .externalDisplay: "an external display"
    case .usbDevice(let device): device.name
    }
  }

  public var telemetryName: String {
    switch self {
    case .power: "power"
    case .ethernet: "ethernet"
    case .externalDisplay: "externalDisplay"
    case .usbDevice: "usbDevice"
    }
  }

  public static func waitingText(_ conditions: [BackupCondition]) -> String {
    let names = conditions.map(\.name)
    guard let last = names.last else { return "" }
    let list = names.count == 1 ? last : "\(names.dropLast().joined(separator: ", ")) and \(last)"
    return "Waiting for \(list)"
  }
}

public struct BackupConditions: Codable, Equatable, Sendable {
  public var power: Bool
  public var ethernet: Bool
  public var externalDisplay: Bool
  public var usbDevice: USBDevice?
  public var runAnywayAfterDays: Int?

  public static let runAnywayChoices = [1, 2, 3, 5, 7, 14]
  public static let none = BackupConditions()

  public init(
    power: Bool = false, ethernet: Bool = false, externalDisplay: Bool = false, usbDevice: USBDevice? = nil,
    runAnywayAfterDays: Int? = 3
  ) {
    self.power = power
    self.ethernet = ethernet
    self.externalDisplay = externalDisplay
    self.usbDevice = usbDevice
    self.runAnywayAfterDays = runAnywayAfterDays
  }

  public var required: [BackupCondition] {
    [power ? .power : nil, ethernet ? .ethernet : nil, externalDisplay ? .externalDisplay : nil]
      .compactMap { $0 } + [usbDevice.map(BackupCondition.usbDevice)].compactMap { $0 }
  }

  public func unmet(in machine: MachineState) -> [BackupCondition] {
    required.filter { !$0.isMet(in: machine) }
  }
}

extension BackupCondition {
  fileprivate func isMet(in machine: MachineState) -> Bool {
    switch self {
    case .power: machine.onPower
    case .ethernet: machine.onEthernet
    case .externalDisplay: machine.hasExternalDisplay
    case .usbDevice(let device): machine.usbDevices.contains { $0.isSameModel(as: device) }
    }
  }
}

public enum ScheduledRunDecision: Equatable, Sendable {
  case notDue
  case run
  case runAnyway(unmet: [BackupCondition])
  case wait(unmet: [BackupCondition])
}

extension AppConfig {
  public func scheduledRunDecision(
    now: Date, calendar: Calendar, machine: () -> MachineState
  ) -> ScheduledRunDecision {
    guard schedule.isDue(lastRun: scheduleReference, now: now, calendar: calendar) else { return .notDue }
    let conditions = backupConditions
    guard !conditions.required.isEmpty else { return .run }
    let unmet = conditions.unmet(in: machine())
    guard !unmet.isEmpty else { return .run }
    if let days = conditions.runAnywayAfterDays,
      let deadline = calendar.date(byAdding: .day, value: days, to: waitingForConditionsSince ?? now),
      deadline <= now
    {
      return .runAnyway(unmet: unmet)
    }
    return .wait(unmet: unmet)
  }
}
