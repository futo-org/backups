import AppKit
import BackupsCore
import SwiftUI

struct BackupWarningsButton: View {
  let warnings: BackupWarnings
  @State private var showing = false

  var body: some View {
    Button {
      showing = true
    } label: {
      Label("Show Warnings", systemImage: "exclamationmark.triangle")
    }
    .buttonStyle(SecondaryButtonStyle(tint: .orange))
    .sheet(isPresented: $showing) {
      BackupWarningsSheet(warnings: warnings)
    }
  }
}

struct BackupWarningsBadge: View {
  let warnings: BackupWarnings
  @State private var showing = false

  var body: some View {
    Button {
      showing = true
    } label: {
      Label(
        warnings.total == 1 ? "1 warning" : "\(warnings.total) warnings", systemImage: "exclamationmark.triangle.fill"
      )
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .foregroundStyle(.orange)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Capsule().fill(Color.orange.opacity(0.12)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("Some files couldn't be backed up. Click to see which.")
    .sheet(isPresented: $showing) {
      BackupWarningsSheet(warnings: warnings)
    }
  }
}

struct BackupWarningsSheet: View {
  let warnings: BackupWarnings
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        IconTile(systemName: "exclamationmark.triangle.fill", tint: .orange, size: 40)
        VStack(alignment: .leading, spacing: 4) {
          Text(warnings.headline)
            .font(.system(size: 20, weight: .bold, design: .rounded))
          Text(
            "The rest of your backup completed. These were skipped this time, and the next backup tries them again."
          )
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(listTitle)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
          Spacer()
          if !remainingPaths.isEmpty {
            Button("Exclude All") { model.addExcludedPaths(remainingPaths) }
              .buttonStyle(.link)
              .font(.system(size: 12))
              .help("Leave all of these out of future backups")
          }
          Button {
            Clipboard.copy(warnings.listText(displayPath: Format.abbreviatedPath))
            copied = true
            Task {
              try? await Task.sleep(for: .seconds(1.5))
              copied = false
            }
          } label: {
            Label(copied ? "Copied" : "Copy List", systemImage: copied ? "checkmark" : "doc.on.doc")
          }
          .buttonStyle(.link)
          .font(.system(size: 12))
        }
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(warnings.items.enumerated()), id: \.offset) { index, warning in
              if index > 0 {
                Divider()
              }
              WarningRow(warning: warning, excluded: model.isExcludedPath(warning.path)) {
                model.addExcludedPaths([warning.path])
              }
            }
          }
        }
        .frame(height: 240)
        .background(CardBackground())
      }
      VStack(alignment: .leading, spacing: 10) {
        Text("Common causes")
          .font(.headline)
        Cause(
          systemName: "lock.fill",
          text: "The file was open or locked by another app. Quit that app before the next backup.")
        Cause(
          systemName: "hand.raised.fill",
          text: "Permission denied or operation not permitted. Give FUTO Backups Full Disk Access in "
            + "System Settings, under Privacy & Security.")
        if !model.hasFullDiskAccess {
          Button("Open Full Disk Access Settings") { openFullDiskAccessSettings() }
            .buttonStyle(.link)
            .font(.system(size: 12))
            .padding(.leading, 28)
        }
        Cause(
          systemName: "arrow.triangle.2.circlepath",
          text: "The file changed or was deleted while the backup was reading it.")
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(PrimaryButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 580)
    .task {
      model.refreshFullDiskAccess()
    }
  }

  private var remainingPaths: [String] {
    warnings.items.map(\.path).filter { !model.isExcludedPath($0) }
  }

  private var listTitle: String {
    warnings.isTruncated
      ? "Showing the first \(warnings.items.count) of \(warnings.total)" : "All \(warnings.total)"
  }

  private func openFullDiskAccessSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
      NSWorkspace.shared.open(url)
    }
  }

  private struct WarningRow: View {
    let warning: BackupWarning
    let excluded: Bool
    let exclude: () -> Void

    var body: some View {
      HStack(spacing: 10) {
        details
        if excluded {
          Text("Excluded")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        } else {
          Button("Exclude", action: exclude)
            .buttonStyle(.link)
            .font(.system(size: 12))
            .help("Leave this out of future backups")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
    }

    private var details: some View {
      VStack(alignment: .leading, spacing: 2) {
        Text(Format.abbreviatedPath(warning.path))
          .font(.system(size: 12, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)
          .help(warning.path)
        Text(warning.reason)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private struct Cause: View {
    let systemName: String
    let text: String

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: systemName)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 20)
        Text(text)
          .font(.system(size: 13))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension BackupWarnings {
  fileprivate var headline: String {
    total == 1 ? "1 file couldn't be backed up" : "\(total) files couldn't be backed up"
  }
}
