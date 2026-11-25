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
    .buttonStyle(.bordered)
    .tint(.orange)
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
      Label {
        Text(warnings.total == 1 ? "1 warning" : "\(warnings.total) warnings")
      } icon: {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      .font(.system(size: 11, weight: .semibold, design: .rounded))
      .foregroundStyle(.primary)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(Capsule().fill(Color.orange.opacity(0.12)))
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help("FUTO Backups could not back up some files. Click to see which.")
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
            "The rest of your backup completed. FUTO Backups could not read all of these this time. The next "
              + "backup tries them again."
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
            Clipboard.copy(warnings.listText())
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
              WarningRow(
                warning: warning, excluded: model.isExcludedPath(warning.path),
                excludable: model.canExcludePath(warning.path)
              ) {
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
          text: "Another app had the file open or locked. Quit that app before the next backup.")
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
          text: "The file changed or was deleted while the backup read it.")
      }
      HStack {
        Spacer()
        Button("Done") { dismiss() }
          .buttonStyle(.borderedProminent)
          .tint(Brand.fill)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 580)
    .onEscape { dismiss() }
    .task {
      model.refreshFullDiskAccess()
    }
  }

  private var remainingPaths: [String] {
    warnings.items.map(\.path).filter { !model.isExcludedPath($0) && model.canExcludePath($0) }
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
    let excludable: Bool
    let exclude: () -> Void

    var body: some View {
      HStack(spacing: 10) {
        details
        if excluded {
          Text("Excluded")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        } else if excludable {
          Button("Exclude", action: exclude)
            .buttonStyle(.link)
            .font(.system(size: 12))
            .help("Leave this out of future backups")
        } else {
          Text("In Folders")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help("This is or contains a folder you chose to back up. To stop backing it up, remove it in Folders.")
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
    total == 1 ? "Could not back up 1 file" : "Could not back up \(total) files"
  }
}
