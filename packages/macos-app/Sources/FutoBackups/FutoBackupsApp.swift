import AppKit
import SwiftUI

@main
struct FutoBackupsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel()

  var body: some Scene {
    Window("FUTO Backups", id: "main") {
      MainWindow()
        .environment(model)
    }
    MenuBarExtra("FUTO Backups", systemImage: "externaldrive.badge.icloud") {
      MenuBarContent()
        .environment(model)
    }
    .menuBarExtraStyle(.menu)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApp.activate()
  }
}
