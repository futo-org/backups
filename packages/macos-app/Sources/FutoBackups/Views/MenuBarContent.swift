import AppKit
import BackupsCore
import SwiftUI

struct MenuBarContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Text(statusLine)
    Text("Last backup: \(lastBackupLine)")
    Text("Next backup: \(nextBackupLine)")
    Divider()
    if model.activity == nil {
      Button("Back up now") { model.backupNow() }
    } else {
      Button("Cancel") { model.cancelBackup() }
    }
    Button("Open FUTO Backups") {
      openWindow(id: "main")
      NSApp.activate()
    }
    Divider()
    Button("Quit") { NSApp.terminate(nil) }
  }

  private var statusLine: String {
    if let setupError = model.setupError {
      return setupError
    }
    if let lastError = model.lastError {
      return lastError
    }
    switch model.activity {
    case .backingUp(let progress): return "Backing up \(Int(progress.percentDone * 100))%"
    case .preparing: return "Preparing…"
    case .pruning: return "Pruning…"
    case .restoring: return "Restoring…"
    case nil: return "Idle"
    }
  }

  private var lastBackupLine: String {
    guard let lastRun = model.config.lastRun else { return "never" }
    return "\(lastRun.status.rawValue.capitalized) \(lastRun.startedAt.formatted(date: .abbreviated, time: .shortened))"
  }

  private var nextBackupLine: String {
    guard let nextRun = model.nextRun else { return "manual only" }
    return nextRun.formatted(.relative(presentation: .named))
  }
}
