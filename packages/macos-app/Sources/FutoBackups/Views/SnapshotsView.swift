import AppKit
import BackupsCore
import SwiftUI

struct SnapshotsView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List(model.snapshots) { snapshot in
      HStack {
        VStack(alignment: .leading) {
          Text(snapshot.time.formatted(date: .abbreviated, time: .shortened))
          Text(snapshot.shortId)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
          Text("\(snapshot.totalFilesProcessed ?? 0) files · \(size(snapshot.totalBytesProcessed))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Restore…") { restore(snapshot) }
      }
    }
    .overlay {
      if model.snapshots.isEmpty {
        Text("No snapshots yet.")
          .foregroundStyle(.secondary)
      }
    }
    .toolbar {
      ToolbarItem {
        Button("Refresh") {
          Task {
            await self.model.refreshSnapshots()
          }
        }
      }
    }
  }

  private func size(_ bytes: Int64?) -> String {
    ByteCountFormatter.string(fromByteCount: bytes ?? 0, countStyle: .file)
  }

  private func restore(_ snapshot: Snapshot) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Restore here"
    if panel.runModal() == .OK, let url = panel.url {
      model.restore(snapshot: snapshot, to: url)
    }
  }
}
