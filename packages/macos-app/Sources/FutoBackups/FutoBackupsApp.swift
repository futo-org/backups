import AppKit
import SwiftUI

@main
struct FutoBackupsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: AppModel
  @State private var updater: Updater

  init() {
    let model = AppModel()
    _model = State(initialValue: model)
    _updater = State(initialValue: Updater(startingUpdater: !model.needsOnboarding))
  }

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
