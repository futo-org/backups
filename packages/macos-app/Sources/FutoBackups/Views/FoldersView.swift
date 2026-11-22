import AppKit
import SwiftUI

struct FoldersView: View {
  @Environment(AppModel.self) private var model
  @State private var dropTargeted = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(title: "Folders", subtitle: "Everything inside these folders is encrypted and backed up.") {
          Button {
            addFolders()
          } label: {
            Label("Add Folder", systemImage: "plus")
          }
          .buttonStyle(PrimaryButtonStyle())
        }
        if model.config.folders.isEmpty {
          dropZone
        } else {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
            ForEach(model.config.folders, id: \.self) { folder in
              FolderCard(path: folder) { model.removeFolder(folder) }
            }
          }
        }
        skipped
        fullDiskAccess
      }
      .padding(28)
      .frame(maxWidth: 820)
      .frame(maxWidth: .infinity)
    }
    .dropDestination(for: URL.self) { urls, _ in
      let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      model.addFolders(folders)
      return !folders.isEmpty
    } isTargeted: {
      dropTargeted = $0
    }
  }

  private var dropZone: some View {
    VStack(spacing: 12) {
      Image(systemName: "folder.badge.plus")
        .font(.system(size: 40, weight: .regular))
        .foregroundStyle(Brand.gradient)
      Text("Drop folders here")
        .font(.system(size: 17, weight: .semibold, design: .rounded))
      Text("or click Add Folder to choose them")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Brand.indigo.opacity(dropTargeted ? 0.12 : 0.04))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
              Brand.indigo.opacity(dropTargeted ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))))
  }

  private var skipped: some View {
    Card {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          IconTile(systemName: "eye.slash.fill", tint: .gray)
          VStack(alignment: .leading, spacing: 2) {
            Text("Skipped automatically")
              .font(.headline)
            Text("Caches, the Trash and cloud-synced folders are left out.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
        FlowLayout(spacing: 6) {
          ForEach(model.config.excludes, id: \.self) { exclude in
            Text(excludeLabel(exclude))
              .font(.system(size: 11, weight: .medium, design: .monospaced))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Capsule().fill(Color.primary.opacity(0.06)))
              .help(exclude)
          }
        }
      }
    }
  }

  private var fullDiskAccess: some View {
    Card {
      HStack(spacing: 12) {
        IconTile(systemName: "lock.shield.fill", tint: .blue)
        VStack(alignment: .leading, spacing: 2) {
          Text("Full Disk Access")
            .font(.headline)
          Text("Lets backups read protected folders like Mail, Messages and Safari.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Open Settings") {
          if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
          }
        }
        .buttonStyle(SecondaryButtonStyle())
      }
    }
  }

  private func excludeLabel(_ pattern: String) -> String {
    pattern.hasPrefix("**/") ? String(pattern.dropFirst(3)) : Format.abbreviatedPath(pattern)
  }

  private func addFolders() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Back Up"
    if panel.runModal() == .OK {
      model.addFolders(panel.urls)
    }
  }
}

struct FolderCard: View {
  let path: String
  let remove: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 12) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: path))
        .resizable()
        .frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 3) {
        Text(URL(fileURLWithPath: path).lastPathComponent)
          .font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
        Text(Format.abbreviatedPath(path))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(CardBackground())
    .overlay(alignment: .topTrailing) {
      Button(action: remove) {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .padding(8)
      .opacity(hovering ? 1 : 0)
      .help("Stop backing up this folder")
    }
    .onHover { hovering = $0 }
    .contextMenu {
      Button("Show in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
      Button("Remove", role: .destructive, action: remove)
    }
  }
}

struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
    let height = rows.last.map { $0.y + $0.height } ?? 0
    let width = rows.map(\.width).max() ?? 0
    return CGSize(width: proposal.width ?? width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for row in arrange(width: bounds.width, subviews: subviews) {
      var x = bounds.minX
      for index in row.indices {
        let size = subviews[index].sizeThatFits(.unspecified)
        subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
    }
  }

  private struct Row {
    var indices: [Int] = []
    var y: CGFloat = 0
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
    var rows: [Row] = []
    var current = Row()
    for index in subviews.indices {
      let size = subviews[index].sizeThatFits(.unspecified)
      let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      if needed > width, !current.indices.isEmpty {
        rows.append(current)
        current = Row(y: current.y + current.height + spacing)
      }
      current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
      current.height = max(current.height, size.height)
      current.indices.append(index)
    }
    if !current.indices.isEmpty { rows.append(current) }
    return rows
  }
}
