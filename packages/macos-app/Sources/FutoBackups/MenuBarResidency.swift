import AppKit
import BackupsCore
import SwiftUI

@MainActor
final class MenuBarResidency {
  static let shared = MenuBarResidency()
  static let mainWindowID = "main"

  var openMainWindow: (() -> Void)?
  private var quitPolicy = QuitPolicy()

  func quit() {
    quitPolicy.chooseQuit()
    NSApp.terminate(nil)
  }

  func updateWillRelaunch() {
    quitPolicy.updateWillRelaunch()
  }

  func updateCycleEnded() {
    quitPolicy.updateCycleEnded()
  }

  func showMainWindow() {
    NSApp.setActivationPolicy(.regular)
    if let window = mainWindows.first {
      window.makeKeyAndOrderFront(nil)
    } else {
      openMainWindow?()
    }
    NSApp.activate()
  }

  func hideToMenuBar() {
    for window in mainWindows {
      window.close()
    }
    NSApp.setActivationPolicy(.accessory)
  }

  func mainWindowWillClose(_ window: NSWindow) {
    guard isMainWindow(window) else { return }
    DispatchQueue.main.async {
      if self.mainWindows.allSatisfy({ !$0.isVisible }) {
        NSApp.setActivationPolicy(.accessory)
      }
    }
  }

  func terminateReply() -> NSApplication.TerminateReply {
    switch quitPolicy.decision(for: Self.currentQuitEvent()) {
    case .quit:
      return .terminateNow
    case .stayInMenuBar:
      hideToMenuBar()
      return .terminateCancel
    }
  }

  static func launchedAsLoginItem() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication)
    else { return false }
    return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
      == OSType(keyAELaunchedAsLogInItem)
  }

  private static func currentQuitEvent() -> QuitEvent? {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication)
    else { return nil }
    let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
    return QuitEvent(
      hasQuitReason: event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        || event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil,
      senderBundleIdentifier: NSRunningApplication(processIdentifier: sender)?.bundleIdentifier)
  }

  private var mainWindows: [NSWindow] {
    NSApp.windows.filter(isMainWindow)
  }

  private func isMainWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.hasPrefix(Self.mainWindowID) == true
  }
}

struct MainWindowOpener: ViewModifier {
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear {
      MenuBarResidency.shared.openMainWindow = { openWindow(id: MenuBarResidency.mainWindowID) }
    }
  }
}

extension View {
  func registersMainWindowOpener() -> some View {
    modifier(MainWindowOpener())
  }
}
