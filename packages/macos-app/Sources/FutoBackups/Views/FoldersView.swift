import AppKit
import BackupsCore
import SwiftUI

struct FoldersView: View {
  @Environment(AppModel.self) private var model
  @State private var dropTargeted = false
  @State private var showPatternEditor = false
  @State private var patternDraft = ""
  @State private var patternError: String?
  @State private var showBuiltInExclusions = false
  @State private var showingExclusions = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if model.config.folders.isEmpty {
          dropZone
          presets
        } else {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 14) {
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
    .navigationTitle("Folders")
    .navigationSubtitle("FUTO Backups encrypts and backs up everything inside these folders.")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add Folder") { addFolders() }
      }
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
        .foregroundStyle(Brand.symbolGradient)
      Text("Drop folders here")
        .font(.system(size: 17, weight: .semibold, design: .rounded))
      Text("or click Add Folder to choose them")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 48)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Brand.blue.opacity(dropTargeted ? 0.12 : 0.04))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
              Brand.blue.opacity(dropTargeted ? 0.8 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))))
  }

  private var presets: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Or start from a preset")
        .font(.system(size: 13, weight: .semibold))
      HStack(alignment: .top, spacing: 12) {
        ForEach(FolderBundle.allCases) { bundle in
          let paths = FolderSelection(home: NSHomeDirectory(), bundle: bundle).paths
          FolderPresetButton(bundle: bundle) {
            model.addFolders(paths.map { URL(fileURLWithPath: $0) })
          }
          .disabled(paths.isEmpty)
        }
      }
    }
  }

  private var skipped: some View {
    let custom = model.customExclusions
    let builtIn = model.config.excludes.filter { model.isDefaultExclusion($0) }
    return Card {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          IconTile(systemName: "eye.slash.fill", tint: .gray)
          VStack(alignment: .leading, spacing: 2) {
            Text("Excluded")
              .font(.headline)
            Text("Folders, files and patterns you leave out of backups.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
        CloudOnlyPolicy(compact: true)
          .padding(10)
          .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
        if custom.isEmpty {
          Text("Nothing excluded yet.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else {
          HStack {
            Text(custom.count == 1 ? "1 excluded item" : "\(custom.count.formatted()) excluded items")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Show List") { showingExclusions = true }
              .buttonStyle(.bordered)
              .accessibilityLabel("Show the list of excluded items")
          }
        }
        HStack(spacing: 8) {
          Button {
            addExclusions()
          } label: {
            Label("Add Folder or File", systemImage: "plus")
          }
          .buttonStyle(.bordered)
          Button {
            patternError = nil
            showPatternEditor = true
          } label: {
            Label("Add Pattern", systemImage: "asterisk")
          }
          .buttonStyle(.bordered)
          .popover(isPresented: $showPatternEditor, arrowEdge: .bottom) {
            patternEditor
          }
          Spacer(minLength: 0)
        }
        Divider()
        DisclosureGroup(isExpanded: $showBuiltInExclusions) {
          VStack(alignment: .leading, spacing: 10) {
            Text("FUTO Backups always skips caches, the Trash, cloud-synced folders and container disk images.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            exclusionChips(builtIn)
            if !model.hasAllDefaultExclusions {
              Button("Restore Built-in Exclusions") { model.restoreDefaultExclusions() }
                .buttonStyle(.link)
            }
          }
          .padding(.top, 8)
        } label: {
          Text("Built-in exclusions (\(builtIn.count))")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
    }
    .sheet(isPresented: $showingExclusions) {
      ExclusionListSheet()
    }
  }

  private func exclusionChips(_ patterns: [String]) -> some View {
    FlowLayout(spacing: 6) {
      ForEach(patterns, id: \.self) { exclude in
        ExclusionChip(label: exclusionLabel(exclude), pattern: exclude, isDefault: model.isDefaultExclusion(exclude)) {
          model.removeExclusion(exclude)
        }
      }
    }
  }

  private var patternEditor: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Exclude a pattern")
        .font(.headline)
      TextField("Pattern", text: $patternDraft, prompt: Text("*.iso"))
        .textFieldStyle(.roundedBorder)
        .onChange(of: patternDraft) { _, _ in patternError = nil }
      if let patternError {
        Text(patternError)
          .font(.caption)
          .foregroundStyle(.red)
      } else {
        Text("For example *.iso, **/build or ~/Downloads/Old. A name without a slash matches everywhere.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Cancel") { showPatternEditor = false }
          .keyboardShortcut(.cancelAction)
        Button("Add", action: addPattern)
          .buttonStyle(.borderedProminent)
          .tint(Brand.fill)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(18)
    .frame(width: 340)
  }

  private var fullDiskAccess: some View {
    Card {
      if model.hasFullDiskAccess {
        HStack(spacing: 12) {
          IconTile(systemName: "checkmark.shield.fill", tint: .green)
          VStack(alignment: .leading, spacing: 2) {
            Text("Full Disk Access")
              .font(.headline)
            Text("Granted. Backups can read protected folders like Mail, Messages and Safari.")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
      } else {
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
          .buttonStyle(.bordered)
        }
      }
    }
  }

  private func addPattern() {
    if let error = model.addExclusionPattern(patternDraft) {
      patternError = error
      return
    }
    patternDraft = ""
    showPatternEditor = false
  }

  private func addExclusions() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = true
    panel.directoryURL = model.config.folders.first.map { URL(fileURLWithPath: $0) }
    panel.prompt = "Exclude"
    panel.message = "Choose folders or files to leave out of backups."
    if panel.runModal() == .OK {
      model.addExclusions(panel.urls)
    }
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

private func exclusionLabel(_ pattern: String) -> String {
  let literal = pattern.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
  return literal.hasPrefix("**/") ? String(literal.dropFirst(3)) : Format.abbreviatedPath(literal)
}

private struct ExclusionListSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var selection = Set<String>()

  var body: some View {
    let all = model.customExclusions
    let shown = matching(all)
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        Text("Excluded")
          .font(.headline)
        Spacer()
        Text(
          query.isEmpty ? "\(all.count.formatted()) items" : "\(shown.count.formatted()) of \(all.count.formatted())"
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
      }
      TextField("Search", text: $query, prompt: Text("Search"))
        .textFieldStyle(.roundedBorder)
        .onChange(of: query) { selection.formIntersection(matching(model.customExclusions)) }
      List(shown, id: \.self, selection: $selection) { pattern in
        HStack(spacing: 8) {
          Text(exclusionLabel(pattern))
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
          if pattern.hasPrefix("!") {
            Spacer(minLength: 0)
            Text("Exception")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(.secondary)
          }
        }
        .help(pattern)
      }
      .listStyle(.bordered(alternatesRowBackgrounds: true))
      .onDeleteCommand { removeSelection(from: shown) }
      HStack {
        Text(
          selection.isEmpty
            ? "Select rules to remove them." : "\(selection.count.formatted()) selected"
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        Spacer()
        Button("Remove") { removeSelection(from: shown) }
          .buttonStyle(.bordered)
          .disabled(selection.isEmpty)
        Button("Done") { dismiss() }
          .buttonStyle(.borderedProminent)
          .tint(Brand.fill)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560, height: 520)
  }

  private func matching(_ patterns: [String]) -> [String] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    guard !needle.isEmpty else { return patterns }
    return patterns.filter {
      $0.localizedCaseInsensitiveContains(needle) || exclusionLabel($0).localizedCaseInsensitiveContains(needle)
    }
  }

  private func removeSelection(from shown: [String]) {
    let removed = selection.intersection(shown)
    guard !removed.isEmpty else { return }
    model.removeExclusions(removed)
    selection.subtract(removed)
  }
}

private struct ExclusionChip: View {
  let label: String
  let pattern: String
  let isDefault: Bool
  let remove: () -> Void
  @State private var hovering = false

  var body: some View {
    HStack(spacing: 4) {
      Text(label)
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundStyle(isDefault ? .secondary : .primary)
      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .opacity(hovering ? 1 : 0.45)
      .help("Stop excluding")
      .accessibilityLabel("Stop excluding \(Format.abbreviatedPath(pattern))")
    }
    .padding(.leading, 8)
    .padding(.trailing, 6)
    .padding(.vertical, 4)
    .background(Capsule().fill(Color.primary.opacity(isDefault ? 0.06 : 0.1)))
    .help(pattern)
    .onHover { hovering = $0 }
  }
}

private struct FolderPresetButton: View {
  let bundle: FolderBundle
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        IconTile(systemName: bundle.systemName, tint: Brand.blue, size: 30)
        Text(bundle.title)
          .font(.system(size: 13, weight: .semibold))
        Text(bundle.detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
      .background(CardBackground())
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.45)
    }
    .buttonStyle(.plain)
  }
}

struct FolderCard: View {
  let path: String
  let remove: () -> Void
  @State private var hovering = false
  @FocusState private var removeFocused: Bool

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
      .focused($removeFocused)
      .padding(8)
      .opacity(hovering || removeFocused ? 1 : 0)
      .help("Stop backing up this folder")
      .accessibilityLabel("Stop backing up \(Format.abbreviatedPath(path))")
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
