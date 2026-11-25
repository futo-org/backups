import AppKit
import SwiftUI

struct AppCommands: Commands {
  let model: AppModel
  @AppStorage(SidebarItem.storageKey) private var page: SidebarItem = .overview

  static let helpURL = URL(string: "https://docs.futo.cloud")!

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("Settings") {
        page = .settings
        MenuBarResidency.shared.showMainWindow()
      }
      .keyboardShortcut(",")
      .disabled(
        !model.sessionLoaded || model.config.telemetryConsentedAt == nil || !model.signedIn || model.needsOnboarding)
    }
    SidebarCommands()
    CommandMenu("Backup") {
      Button("Back Up Now") { model.backupNow() }
        .keyboardShortcut("b")
        .disabled(!model.canBackUpNow)
      Button(model.activity == .restoring ? "Cancel Restore" : "Cancel Backup") { model.cancelBackup() }
        .keyboardShortcut(".")
        .disabled(!model.canCancelActivity)
    }
    CommandGroup(replacing: .help) {
      Button("FUTO Backups Help") { NSWorkspace.shared.open(Self.helpURL) }
    }
  }
}
