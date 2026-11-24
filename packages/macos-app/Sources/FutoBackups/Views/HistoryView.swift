import AppKit
import BackupsCore
import SwiftUI

struct HistoryView: View {
  @Environment(AppModel.self) private var model
  @State private var refreshing = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(title: "History", subtitle: "Snapshots from the last 60 days. Restore any of them to a folder.") {
          Button {
            Task {
              refreshing = true
              await model.refreshSnapshots()
              refreshing = false
            }
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(refreshing)
        }
        if !model.restoredFolders.isEmpty {
          Banner(
            systemName: "checkmark.circle.fill", tint: .green, text: "Restore complete", actionTitle: "Show in Finder",
            action: { NSWorkspace.shared.activateFileViewerSelecting(model.restoredFolders) },
            dismiss: { model.restoredFolders = [] })
        }
        if case .restoring = model.activity {
          Banner(systemName: "arrow.down.circle.fill", tint: Brand.blue, text: "Restoring files…") {}
        }
        if model.snapshots.isEmpty {
          empty
        } else {
          ForEach(groups, id: \.day) { group in
            VStack(alignment: .leading, spacing: 8) {
              Text(Format.day(group.day))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
              VStack(spacing: 0) {
                ForEach(Array(group.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                  if index > 0 {
                    Divider()
                      .padding(.leading, 54)
                  }
                  SnapshotRow(snapshot: snapshot, latest: snapshot.id == model.snapshots.first?.id) {
                    restore(snapshot)
                  }
                }
              }
              .background(CardBackground())
            }
          }
        }
      }
      .padding(28)
      .frame(maxWidth: 820)
      .frame(maxWidth: .infinity)
    }
  }

  private var empty: some View {
    VStack(spacing: 10) {
      Image(systemName: "clock.arrow.circlepath")
        .font(.system(size: 38))
        .foregroundStyle(Brand.gradient)
      Text("No snapshots yet")
        .font(.system(size: 17, weight: .semibold, design: .rounded))
      Text("Your first backup will show up here.")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 60)
  }

  private var groups: [(day: Date, snapshots: [Snapshot])] {
    let calendar = Calendar.current
    let grouped = Dictionary(grouping: model.snapshots) { calendar.startOfDay(for: $0.time) }
    return grouped.keys.sorted(by: >).map { day in
      (day, grouped[day, default: []].sorted { $0.time > $1.time })
    }
  }

  private func restore(_ snapshot: Snapshot) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Restore Here"
    panel.message =
      "Choose where to restore the snapshot from \(Format.relative(snapshot.time, inSentence: true)). "
      + "Each backed-up folder is restored inside it under its own name."
    if panel.runModal() == .OK, let url = panel.url {
      model.restore(snapshot: snapshot, to: url)
    }
  }
}

struct SnapshotRow: View {
  let snapshot: Snapshot
  let latest: Bool
  let restore: () -> Void
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(latest ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
          .frame(width: 28, height: 28)
        Image(systemName: latest ? "checkmark" : "camera.aperture")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(latest ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(snapshot.time.formatted(date: .omitted, time: .shortened))
            .font(.system(size: 14, weight: .semibold))
          if latest {
            Text("Latest")
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(Brand.blue)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Capsule().fill(Brand.blue.opacity(0.14)))
          }
        }
        Text(
          "\(snapshot.totalFilesProcessed ?? 0) files · \(Format.bytes(snapshot.totalBytesProcessed))"
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      }
      Spacer()
      if let added = snapshot.dataAdded {
        Text("+\(Format.bytes(added))")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.green)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Capsule().fill(Color.green.opacity(0.12)))
          .help("New data uploaded by this backup")
      }
      Text(snapshot.shortId)
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
      Button("Restore…", action: restore)
        .buttonStyle(SecondaryButtonStyle())
        .disabled(model.activity != nil)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 11)
  }
}
