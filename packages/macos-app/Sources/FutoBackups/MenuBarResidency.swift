import AppKit
import SwiftUI

@MainActor
final class MenuBarResidency {
  static let shared = MenuBarResidency()
  static let mainWindowID = "main"

  var openMainWindow: (() -> Void)?
  private var quitRequested = false

  func quit() {
    quitRequested = true
    NSApp.terminate(nil)
  }

  func allowQuit() {
    quitRequested = true
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
    if quitRequested || Self.quitComesFromSystemOrScript() {
      return .terminateNow
    }
    hideToMenuBar()
    return .terminateCancel
  }

  static func launchedAsLoginItem() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication)
    else { return false }
    return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
      == OSType(keyAELaunchedAsLogInItem)
  }

  private static func quitComesFromSystemOrScript() -> Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent,
      event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication)
    else { return false }
    if event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
      || event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    {
      return true
    }
    let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
    return NSRunningApplication(processIdentifier: sender)?.bundleIdentifier != "com.apple.dock"
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
