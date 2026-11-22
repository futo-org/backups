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
        .tint(Brand.blue)
    }
    .windowStyle(.hiddenTitleBar)
    .windowToolbarStyle(.unified)
    .defaultSize(width: 980, height: 680)
    MenuBarExtra {
      MenuBarContent()
        .environment(model)
        .tint(Brand.blue)
    } label: {
      Image(systemName: StatusSummary(model: model).menuBarSymbol)
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
