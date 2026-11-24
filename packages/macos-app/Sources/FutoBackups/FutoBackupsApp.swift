import AppKit
import SwiftUI

@main
struct FutoBackupsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model = AppModel()
  @State private var updater = Updater()

  var body: some Scene {
    Window("FUTO Backups", id: "main") {
      MainWindow()
        .environment(model)
        .environment(updater)
        .tint(Brand.blue)
    }
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unified)
    .defaultSize(width: 980, height: 680)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates…") { updater.checkForUpdates() }
          .disabled(!updater.canCheckForUpdates)
      }
    }
    MenuBarExtra {
      MenuBarContent()
        .environment(model)
        .environment(updater)
        .tint(Brand.blue)
    } label: {
      MenuBarLabel(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApp.activate()
  }
}
