import AppKit
import SwiftUI

@main
struct FutoBackupsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: AppModel
  @State private var updater: Updater

  init() {
    // GitHub serves the update feed without cache headers, so a cached copy of the previous feed hides new releases.
    URLCache.shared = URLCache(memoryCapacity: 0, diskCapacity: 0)
    let model = AppModel()
    _model = State(initialValue: model)
    _updater = State(initialValue: Updater(startingUpdater: !model.needsOnboarding))
  }

  var body: some Scene {
    Window("FUTO Backups", id: MenuBarResidency.mainWindowID) {
      MainWindow()
        .environment(model)
        .environment(updater)
        .tint(Brand.blue)
        .registersMainWindowOpener()
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
        .registersMainWindowOpener()
    } label: {
      MenuBarLabel(model: model)
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var launchedAsLoginItem = false
  private var windowCloseObserver: (any NSObjectProtocol)?

  func applicationWillFinishLaunching(_ notification: Notification) {
    launchedAsLoginItem = MenuBarResidency.launchedAsLoginItem()
    if launchedAsLoginItem {
      NSApplication.shared.setActivationPolicy(.accessory)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    windowCloseObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated { MenuBarResidency.shared.mainWindowWillClose(window) }
    }
    if launchedAsLoginItem {
      DispatchQueue.main.async { MenuBarResidency.shared.hideToMenuBar() }
    } else {
      NSApplication.shared.setActivationPolicy(.regular)
      NSApp.activate()
    }
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    MenuBarResidency.shared.terminateReply()
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
      MenuBarResidency.shared.showMainWindow()
    }
    return true
  }
}
