import AppKit
import SwiftUI

struct FoldersView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List {
      Section {
        if model.config.folders.isEmpty {
          Text("No folders yet.")
            .foregroundStyle(.secondary)
        }
        ForEach(model.config.folders, id: \.self) { folder in
          HStack {
            Text(folder)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer()
            Button(role: .destructive) {
              model.removeFolder(folder)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
          }
        }
      } header: {
        HStack {
          Text("Folders")
          Spacer()
          Button {
            addFolders()
          } label: {
            Image(systemName: "plus")
          }
        }
      }
      Section("Full Disk Access") {
        Text("Grant Full Disk Access so backups can read every file in the selected folders.")
          .foregroundStyle(.secondary)
        Button("Open System Settings") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
          }
        }
      }
    }
  }

  private func addFolders() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK {
      model.addFolders(panel.urls)
    }
  }
}
