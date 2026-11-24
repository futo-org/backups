import AppKit
import BackupsCore
import SwiftUI
import UniformTypeIdentifiers

struct SnapshotBrowserView: View {
  @Bindable var browser: SnapshotBrowser
  let canRestore: Bool
  let restore: ([SnapshotEntry]) -> Void
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 14) {
        IconTile(systemName: "doc.on.doc.fill", tint: Brand.blue, size: 40)
        VStack(alignment: .leading, spacing: 4) {
          Text("Restore Files")
            .font(.system(size: 20, weight: .bold, design: .rounded))
          Text(
            "Pick files and folders from the snapshot from \(Format.relative(browser.snapshot.time, inSentence: true))."
          )
          .font(.system(size: 13))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      PathBar(browser: browser)
      VStack(spacing: 0) {
        ColumnHeader()
        Divider()
        content
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .background(CardBackground())
      footer
    }
    .padding(24)
    .frame(width: 700, height: 560)
  }

  @ViewBuilder
  private var content: some View {
    switch browser.listing {
    case .loading:
      ProgressView()
        .controlSize(.small)
    case .failed(let message):
      VStack(spacing: 10) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 30))
          .foregroundStyle(.orange)
        Text("Couldn't open this folder")
          .font(.system(size: 15, weight: .semibold, design: .rounded))
        Text(message)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
          .copyable(message)
        Button("Try Again") { browser.retry() }
          .buttonStyle(SecondaryButtonStyle())
          .padding(.top, 4)
      }
      .padding(20)
    case .loaded(let entries) where entries.isEmpty:
      Text("This folder is empty")
        .foregroundStyle(.secondary)
    case .loaded(let entries):
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(entries) { entry in
            EntryRow(
              entry: entry, showsPath: browser.isAtRoot,
              included: browser.selection.isIncluded(entry),
              coveredByFolder: browser.selection.isCoveredByFolder(entry),
              toggle: { browser.selection.toggle(entry) },
              open: { browser.open(entry) })
          }
        }
        .padding(.vertical, 4)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      if browser.selection.isEmpty {
        Text("Check the files and folders to restore.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      } else {
        Text(itemCount(browser.selection.count).lowercased() + " selected")
          .font(.system(size: 12, weight: .medium))
        Button("Clear") { browser.selection.removeAll() }
          .buttonStyle(.link)
          .font(.system(size: 12))
      }
      Spacer()
      Button("Cancel", action: close)
        .buttonStyle(SecondaryButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button(browser.selection.isEmpty ? "Restore" : "Restore \(itemCount(browser.selection.count))") {
        restore(browser.selection.entries)
      }
      .buttonStyle(PrimaryButtonStyle())
      .keyboardShortcut(.defaultAction)
      .disabled(browser.selection.isEmpty || !canRestore)
      .help(canRestore ? "" : "Wait for the current backup or restore to finish")
    }
  }

  private func itemCount(_ count: Int) -> String {
    count == 1 ? "1 Item" : "\(count) Items"
  }
}

private struct PathBar: View {
  let browser: SnapshotBrowser

  var body: some View {
    HStack(spacing: 6) {
      Button(action: browser.goBack) {
        Image(systemName: "chevron.left")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 24, height: 24)
          .background(Circle().fill(Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .disabled(browser.isAtRoot)
      .opacity(browser.isAtRoot ? 0.45 : 1)
      .keyboardShortcut("[", modifiers: .command)
      .help("Back")
      .accessibilityLabel("Back")
      crumb("Backed-Up Folders", depth: 0)
      ForEach(Array(browser.trail.enumerated()), id: \.element.id) { index, entry in
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .bold))
          .foregroundStyle(.tertiary)
        crumb(entry.name, depth: index + 1)
      }
      Spacer(minLength: 0)
    }
  }

  @ViewBuilder
  private func crumb(_ title: String, depth: Int) -> some View {
    if depth == browser.trail.count {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.middle)
        .layoutPriority(1)
    } else {
      Button(title) { browser.goTo(depth: depth) }
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }
}

private struct ColumnHeader: View {
  var body: some View {
    HStack(spacing: 10) {
      Text("Name")
        .padding(.leading, 26 + 10)
      Spacer()
      Text("Date Modified")
        .frame(width: EntryRow.dateWidth, alignment: .leading)
      Text("Size")
        .frame(width: EntryRow.sizeWidth, alignment: .trailing)
      Color.clear
        .frame(width: EntryRow.chevronWidth, height: 1)
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

private struct EntryRow: View {
  static let dateWidth: CGFloat = 160
  static let sizeWidth: CGFloat = 70
  static let chevronWidth: CGFloat = 20

  let entry: SnapshotEntry
  let showsPath: Bool
  let included: Bool
  let coveredByFolder: Bool
  let toggle: () -> Void
  let open: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Toggle(entry.name, isOn: Binding(get: { included }, set: { _ in toggle() }))
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(coveredByFolder)
        .help(coveredByFolder ? "Included with its folder" : "")
      Image(nsImage: FileIcon.image(for: entry, live: showsPath))
        .resizable()
        .frame(width: 20, height: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(entry.name)
          .font(.system(size: 13))
          .lineLimit(1)
          .truncationMode(.middle)
        if showsPath {
          Text(Format.abbreviatedPath(entry.path))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      Spacer(minLength: 8)
      Group {
        Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "--")
          .frame(width: Self.dateWidth, alignment: .leading)
        Text(entry.kind == .file ? Format.bytes(entry.size) : "--")
          .monospacedDigit()
          .frame(width: Self.sizeWidth, alignment: .trailing)
      }
      .font(.system(size: 12))
      .foregroundStyle(.secondary)
      Group {
        if entry.isDirectory {
          Button(action: open) {
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(.secondary)
              .frame(width: Self.chevronWidth, height: 20)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .help("Open \(entry.name)")
          .accessibilityLabel("Open \(entry.name)")
        } else {
          Color.clear
        }
      }
      .frame(width: Self.chevronWidth)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, showsPath ? 6 : 5)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(included ? Brand.blue.opacity(0.12) : Color.clear)
        .padding(.horizontal, 4)
    )
    .contentShape(Rectangle())
    .gesture(entry.isDirectory ? TapGesture(count: 2).onEnded(open) : TapGesture().onEnded(toggleFile))
  }

  private func toggleFile() {
    if !coveredByFolder {
      toggle()
    }
  }
}

enum FileIcon {
  @MainActor
  static func image(for entry: SnapshotEntry, live: Bool) -> NSImage {
    let workspace = NSWorkspace.shared
    if entry.path == SnapshotListing.rootPath {
      return workspace.icon(for: .volume)
    }
    if live, FileManager.default.fileExists(atPath: entry.path) {
      return workspace.icon(forFile: entry.path)
    }
    let pathExtension = (entry.name as NSString).pathExtension
    switch entry.kind {
    case .directory:
      if let bundle = UTType(filenameExtension: pathExtension, conformingTo: .directory), bundle.conforms(to: .package)
      {
        return workspace.icon(for: bundle)
      }
      return workspace.icon(for: .folder)
    case .file, .symlink, .other:
      return workspace.icon(for: UTType(filenameExtension: pathExtension) ?? .data)
    }
  }
}
