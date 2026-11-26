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
        Label {
          Text(error)
            .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
        .font(.system(size: 11))
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
          .tint(Brand.fill)
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
      HStack(spacing: 4) {
        MenuIconButton(title: "Settings", symbol: "gearshape") {
          MenuBarResidency.shared.showMainWindow()
        }
        Spacer()
        if updater.isAvailable {
          MenuIconButton(title: "Check for Updates", symbol: "arrow.trianglehead.2.clockwise.rotate.90") {
            updater.checkForUpdates()
          }
          .disabled(!updater.canCheckForUpdates)
        }
        MenuIconButton(title: "Quit", symbol: "power") { MenuBarResidency.shared.quit() }
      }
      .padding(-6)
    }
    .padding(16)
    .frame(width: 300)
  }

  private var nextBackup: String {
    if model.activity != nil { return "Running now" }
    if !model.waitingFor.isEmpty { return BackupCondition.waitingText(model.waitingFor) }
    guard let nextRun = model.nextRun else { return "Manual" }
    return nextRun <= .now ? "Due now" : Format.relative(nextRun)
  }
}

struct MenuBarLabel: View {
  let model: AppModel

  var body: some View {
    let status = StatusSummary(model: model, progress: nil)
    Image(systemName: status.menuBarSymbol)
      .accessibilityLabel("FUTO Backups")
      .accessibilityValue(model.signedIn ? status.title : "Not signed in")
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

private struct MenuIconButton: View {
  let title: String
  let symbol: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .labelStyle(.iconOnly)
    }
    .buttonStyle(MenuIconButtonStyle())
    .help(title)
  }
}

private struct MenuIconButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    MenuIcon(configuration: configuration)
  }

  private struct MenuIcon: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
      configuration.label
        .font(.system(size: 14))
        .foregroundStyle(isEnabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .frame(width: 28, height: 28)
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
