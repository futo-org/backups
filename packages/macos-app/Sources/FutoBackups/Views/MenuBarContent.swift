import AppKit
import BackupsCore
import SwiftUI

struct MenuBarContent: View {
  @Environment(AppModel.self) private var model
  @Environment(Updater.self) private var updater
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let status = StatusSummary(model: model)
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        StatusRing(
          progress: status.progress, busy: status.busy, symbol: status.symbol, tint: status.tint, size: 42)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.signedIn ? status.title : "Not signed in")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
          Text(model.signedIn ? status.compactSubtitle ?? status.subtitle : "Open FUTO Backups to sign in.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer(minLength: 0)
        AlphaBadge()
      }
      if let error = model.lastError ?? model.setupError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 11))
          .foregroundStyle(.orange)
          .lineLimit(3)
          .copyable(error)
      }
      if model.signedIn {
        VStack(spacing: 8) {
          InfoRow(label: "Last backup", value: model.config.lastRun.map { Format.relative($0.finishedAt) } ?? "Never")
          InfoRow(label: "Next backup", value: nextBackup)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        if model.activity == nil {
          Button {
            model.backupNow()
          } label: {
            Text("Back Up Now")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(PrimaryButtonStyle())
          .disabled(model.config.folders.isEmpty)
        } else {
          Button {
            model.cancelBackup()
          } label: {
            Text("Cancel")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(SecondaryButtonStyle())
        }
      }
      Divider()
      HStack {
        Button("Open FUTO Backups") {
          openWindow(id: "main")
          NSApp.activate()
        }
        if updater.isAvailable {
          Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        }
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
          .keyboardShortcut("q")
      }
      .buttonStyle(.borderless)
      .font(.system(size: 12))
    }
    .padding(16)
    .frame(width: 300)
  }

  private var nextBackup: String {
    if model.activity != nil { return "Running now" }
    guard let nextRun = model.nextRun else { return "Manual" }
    return nextRun <= .now ? "Due now" : Format.relative(nextRun)
  }
}

struct InfoRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .fontWeight(.medium)
    }
    .font(.system(size: 12))
  }
}
