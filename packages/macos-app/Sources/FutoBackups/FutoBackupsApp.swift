import AppKit
import BackupsCore
import SwiftUI

@main
struct FutoBackupsApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var model: AppModel
  @State private var updater: Updater

  init() {
    let model = AppModel()
    _model = State(initialValue: model)
    AppDelegate.model = model
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
    .windowToolbarStyle(.unified)
    .defaultSize(width: 980, height: 680)
    .commands {
      CommandGroup(after: .appInfo) {
        Button("Check for Updates") { updater.checkForUpdates() }
          .disabled(!updater.canCheckForUpdates)
      }
      AppCommands(model: model)
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
  static var model: AppModel?
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

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    guard let model = Self.model, model.signedIn else { return nil }
    let item: NSMenuItem
    switch QuickBackupAction(model: model) {
    case .cancel(let activity):
      dockMenuActivity = activity
      item = NSMenuItem(
        title: activity == .restoring ? "Cancel Restore" : "Cancel Backup", action: #selector(cancelBackup),
        keyEquivalent: "")
    case .backUp(let enabled):
      dockMenuActivity = nil
      item = NSMenuItem(title: "Back Up Now", action: #selector(backUpNow), keyEquivalent: "")
      item.isEnabled = enabled
    }
    item.target = self
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(item)
    return menu
  }

  private var dockMenuActivity: ActivityPhase?

  @objc private func backUpNow() {
    Self.model?.backupNow()
  }

  @objc private func cancelBackup() {
    guard let model = Self.model, let shown = dockMenuActivity, model.activity == shown else { return }
    model.cancelBackup()
  }
}
