import AppKit
import BackupsCore
import SwiftUI

struct MenuBarContent: View {
  @Environment(AppModel.self) private var model
  @Environment(Updater.self) private var updater

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      MenuBarStatus(progress: model.activityProgress)
      if model.signedIn, model.activity == .backingUp {
        MenuBarUploadSpeed(progress: model.activityProgress)
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
          .buttonStyle(.borderedProminent)
          .disabled(model.config.folders.isEmpty)
        } else if !model.isCancelling, model.activity?.isCancellable == true {
          Button {
            model.cancelBackup()
          } label: {
            Text("Cancel")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
        }
      }
      Divider()
      VStack(spacing: 0) {
        Button("Open FUTO Backups") {
          MenuBarResidency.shared.showMainWindow()
        }
        if updater.isAvailable {
          Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
        }
        Button("Quit FUTO Backups") { MenuBarResidency.shared.quit() }
          .help("Stops FUTO Backups, including scheduled backups, until you open it again")
      }
      .buttonStyle(MenuRowButtonStyle())
      .padding(.horizontal, -8)
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

struct MenuBarLabel: View {
  let model: AppModel

  var body: some View {
    Image(systemName: StatusSummary(model: model, progress: nil).menuBarSymbol)
  }
}

private struct MenuBarStatus: View {
  @Environment(AppModel.self) private var model
  let progress: ActivityProgressStore

  var body: some View {
    let status = StatusSummary(model: model, progress: progress.progress, restore: progress.restore)
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
  }
}

private struct MenuBarUploadSpeed: View {
  let progress: ActivityProgressStore

  var body: some View {
    if let speed = progress.speed {
      UploadSpeedBadge(speed: speed)
    }
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

private struct MenuRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MenuRow(configuration: configuration)
  }

  private struct MenuRow: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 13))
        .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.primary.opacity(highlight))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var highlight: Double {
      guard isEnabled else { return 0 }
      if configuration.isPressed { return 0.16 }
      return hovering ? 0.1 : 0
    }
  }
}
