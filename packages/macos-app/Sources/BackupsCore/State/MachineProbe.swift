import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import Network
import Synchronization

public final class MachineProbe: Sendable {
  private let ethernet = Mutex(false)
  private let monitor = NWPathMonitor()

  public init() {}

  public func start(onNetworkChange: @escaping @Sendable () -> Void) {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let onEthernet = path.status == .satisfied && path.usesInterfaceType(.wiredEthernet)
      let changed = self.ethernet.withLock { previous in
        defer { previous = onEthernet }
        return previous != onEthernet
      }
      if changed { onNetworkChange() }
    }
    monitor.start(queue: DispatchQueue(label: "org.futo.backups.machine-probe"))
  }

  public func stop() {
    monitor.cancel()
  }

  public func current() -> MachineState {
    MachineState(
      onPower: Self.isOnPower(), onEthernet: ethernet.withLock { $0 },
      hasExternalDisplay: Self.hasExternalDisplay(), usbDevices: Self.usbDevices())
  }

  public static func isOnPower() -> Bool {
    let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
    return (type as String) == kIOPMACPowerKey
  }

  public static func hasExternalDisplay() -> Bool {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
    return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
  }

  public static func usbDevices() -> [USBDevice] {
    var iterator: io_iterator_t = 0
    guard
      IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
        == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iterator) }
    var devices: [USBDevice] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
      defer { IOObjectRelease(service) }
      guard let vendorId = property(service, "idVendor") as? Int,
        let productId = property(service, "idProduct") as? Int
      else { continue }
      let name =
        (property(service, "USB Product Name") as? String) ?? (property(service, "kUSBProductString") as? String)
        ?? "USB device"
      let device = USBDevice(vendorId: vendorId, productId: productId, name: name)
      if !devices.contains(where: { $0.isSameModel(as: device) }) {
        devices.append(device)
      }
    }
    return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private static func property(_ service: io_object_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
  }
}
