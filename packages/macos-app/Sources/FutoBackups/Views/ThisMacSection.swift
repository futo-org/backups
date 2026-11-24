import AppKit
import BackupsCore
import SwiftUI

enum BackupDeletionState: Equatable {
  case idle
  case starting
  case confirmingInBrowser(URL)
  case removingThisMac
  case macStillLinked(otherRepositories: [RemoteRepository], detail: String?)
  case failed(String)

  init(error: any Error) {
    switch error {
    case is CancellationError:
      self = .idle
    case BackupDeletionError.timedOut:
      self = .failed("The deletion wasn't confirmed in the browser within 15 minutes. Nothing was deleted.")
    case BackupDeletionError.noConnection:
      self = .failed("This Mac isn't linked to its own connection on FUTO Cloud, so its backup can't be deleted here.")
    case BackupDeletionError.connectionNotDeleted(let detail):
      self = .macStillLinked(otherRepositories: [], detail: detail)
    case YuccaError.unauthorized:
      self = .failed("Your session expired. Sign in again, then retry. Nothing was deleted.")
    default:
      self = .failed("Something went wrong: \(error)")
    }
  }

  var isRunning: Bool {
    switch self {
    case .starting, .confirmingInBrowser, .removingThisMac: true
    default: false
    }
  }
}

private enum ThisMacSheet: String, Identifiable {
  case reset
  case deleteBackup

  var id: String { rawValue }
}

struct ThisMacSection: View {
  @Environment(AppModel.self) private var model
  @State private var sheet: ThisMacSheet?

  var body: some View {
    Section("Remove This Mac") {
      LabeledContent {
        Button("Unlink This Mac…") { sheet = .reset }
          .buttonStyle(.bordered)
          .tint(.orange)
      } label: {
        SettingLabel(
          systemName: "arrow.counterclockwise", tint: .orange, title: "Unlink this Mac",
          detail:
            "Remove FUTO Backups' settings, sign-in and recovery key from this Mac. Its backup stays on FUTO Cloud and this Mac stays listed in your account."
        )
      }
      .labeledContentStyle(.centered)
      .padding(.vertical, 4)
      LabeledContent {
        Button("Delete This Mac's Backup…", role: .destructive) { sheet = .deleteBackup }
          .buttonStyle(.bordered)
          .tint(.red)
      } label: {
        SettingLabel(
          systemName: "trash.fill", tint: .red, title: "Delete this Mac's backup",
          detail:
            "Permanently delete this Mac's backup and its history from FUTO Cloud, and remove this Mac from your account."
        )
      }
      .labeledContentStyle(.centered)
      .padding(.vertical, 4)
    }
    .disabled(model.isResetting)
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case .reset: ResetThisMacSheet { self.sheet = nil }
      case .deleteBackup: DeleteBackupSheet { self.sheet = nil }
      }
    }
  }
}

private struct SheetHeader: View {
  let systemName: String
  let tint: Color
  let title: String

  var body: some View {
    VStack(spacing: 10) {
      IconTile(systemName: systemName, tint: tint, size: 44)
      Text(title)
        .font(.system(size: 20, weight: .bold, design: .rounded))
        .multilineTextAlignment(.center)
    }
  }
}

private struct SheetText: View {
  let text: String

  init(_ text: String) {
    self.text = text
  }

  var body: some View {
    Text(text)
      .font(.system(size: 13))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct ResetThisMacSheet: View {
  @Environment(AppModel.self) private var model
  let close: () -> Void
  @State private var recoveryKey: String?
  @State private var revealing = false
  @State private var hasRecoveryKey = false
  @State private var resetting = false

  var body: some View {
    VStack(spacing: 18) {
      SheetHeader(systemName: "arrow.counterclockwise", tint: .orange, title: "Unlink This Mac?")
      SheetText(
        "This removes FUTO Backups' settings, sign-in, recovery key and cache from this Mac. Your backup stays on FUTO Cloud and this Mac stays listed in your account. To pick it up again later, sign in and enter your recovery key."
      )
      if let recoveryKey {
        RecoveryKeyCard(key: recoveryKey)
        RecoveryKeyActions(key: recoveryKey)
      } else {
        Button("Show Recovery Key") {
          revealing = true
          Task {
            recoveryKey = await model.revealRecoveryKey()
            revealing = false
          }
        }
        .buttonStyle(.bordered)
        .disabled(revealing)
      }
      Toggle(isOn: $hasRecoveryKey) {
        Text("I have my recovery key. Without it, this Mac's backup can't be restored.")
          .font(.system(size: 13, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
      }
      .toggleStyle(.checkbox)
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 12) {
        Button("Cancel", action: close)
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
        Spacer()
        if resetting {
          ProgressView()
            .controlSize(.small)
        }
        Button("Unlink This Mac", role: .destructive) {
          resetting = true
          Task {
            await model.resetThisMac()
            resetting = false
            close()
          }
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(!hasRecoveryKey || resetting)
      }
    }
    .disabled(resetting)
    .padding(28)
    .frame(width: 480)
    .interactiveDismissDisabled(resetting)
  }
}

private struct DeleteBackupSheet: View {
  @Environment(AppModel.self) private var model
  let close: () -> Void
  @State private var understood = false

  var body: some View {
    VStack(spacing: 18) {
      switch model.backupDeletion {
      case .idle:
        confirmation
      case .starting:
        progress("Opening your browser…")
      case .confirmingInBrowser(let url):
        waiting(url)
      case .removingThisMac:
        progress("Removing this Mac from your account…")
      case .macStillLinked(let otherRepositories, let detail):
        stillLinked(otherRepositories, detail: detail)
      case .failed(let message):
        failed(message)
      }
    }
    .padding(28)
    .frame(width: 480)
    .interactiveDismissDisabled(model.backupDeletion.isRunning || model.isResetting)
    .onDisappear { model.dismissBackupDeletion() }
  }

  private var confirmation: some View {
    Group {
      SheetHeader(systemName: "trash.fill", tint: .red, title: "Delete This Mac's Backup?")
      SheetText(
        "The backup \(model.config.host) uses, and all its history, will be permanently deleted from FUTO Cloud. This can't be undone. Your other Macs' backups aren't affected. This Mac is then removed from your account, and FUTO Backups' settings, sign-in, recovery key and cache are cleared from it."
      )
      SheetText("Your browser opens to confirm: sign in again, then click Permanently Delete.")
      Toggle(isOn: $understood) {
        Text("I understand this Mac's backup history will be permanently deleted.")
          .font(.system(size: 13, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
      }
      .toggleStyle(.checkbox)
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 12) {
        Button("Cancel", action: dismiss)
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Delete Backup…", role: .destructive) { model.startBackupDeletion() }
          .buttonStyle(.bordered)
          .tint(.red)
          .disabled(!understood)
      }
    }
  }

  private func progress(_ title: String) -> some View {
    VStack(spacing: 14) {
      ProgressView()
      Text(title)
        .font(.system(size: 13, weight: .medium))
    }
    .padding(.vertical, 24)
  }

  private func waiting(_ url: URL) -> some View {
    Group {
      SheetHeader(systemName: "safari", tint: Brand.blue, title: "Confirm the deletion in your browser")
      SheetText(
        "Sign in again, then click Permanently Delete. This window updates once the backup is deleted.")
      ProgressView()
        .controlSize(.small)
      HStack(spacing: 12) {
        Button("Cancel") {
          model.cancelBackupDeletion()
          close()
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Open Browser Again") { NSWorkspace.shared.open(url) }
          .buttonStyle(.bordered)
      }
    }
  }

  private func stillLinked(_ repositories: [RemoteRepository], detail: String?) -> some View {
    Group {
      SheetHeader(systemName: "exclamationmark.triangle.fill", tint: .orange, title: "Backup deleted")
      if repositories.isEmpty {
        SheetText(
          "This Mac's backup was deleted from FUTO Cloud, but this Mac couldn't be removed from your account. Try again, or clear this Mac's local data anyway; it stays listed in your account."
        )
      } else {
        SheetText(
          "This Mac's backup was deleted from FUTO Cloud, but this Mac is still linked to other backups, so it wasn't removed from your account:"
        )
        VStack(alignment: .leading, spacing: 6) {
          ForEach(repositories) { repository in
            Label(repository.name, systemImage: "externaldrive")
              .font(.system(size: 13, weight: .medium))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(CardBackground())
        SheetText(
          "Delete them from the FUTO Backups website, or clear this Mac's local data now and leave them listed.")
      }
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(3)
      }
      HStack(spacing: 12) {
        Button("Close", action: dismiss)
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
        Spacer()
        if repositories.isEmpty {
          Button("Try Again") { model.startBackupDeletion() }
            .buttonStyle(.bordered)
        }
        Button("Clear Local Data Anyway", role: .destructive) {
          Task { await model.resetAfterBackupDeletion() }
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .disabled(model.isResetting)
      }
    }
  }

  private func failed(_ message: String) -> some View {
    Group {
      SheetHeader(systemName: "exclamationmark.triangle.fill", tint: .orange, title: "Couldn't delete the backup")
      SheetText(message)
      HStack(spacing: 12) {
        Button("Close", action: dismiss)
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Try Again") { model.startBackupDeletion() }
          .buttonStyle(.bordered)
      }
    }
  }

  private func dismiss() {
    model.dismissBackupDeletion()
    close()
  }
}
