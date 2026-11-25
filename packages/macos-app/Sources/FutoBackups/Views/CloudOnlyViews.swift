import BackupsCore
import SwiftUI

struct CloudOnlyPolicy: View {
  var compact = false

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "icloud.slash")
        .font(.system(size: compact ? 13 : 15, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text("Files kept only in the cloud are not backed up")
          .font(.system(size: compact ? 12 : 13, weight: .semibold))
        Text(
          "FUTO Backups skips iCloud Drive, Dropbox, OneDrive and Google Drive files that are not on this Mac. "
            + "To include them, choose Keep Downloaded in Finder."
        )
        .font(.system(size: compact ? 11 : 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

struct CloudOnlyNotice: View {
  let skipped: CloudOnlySkip
  @State private var showingFiles = false

  var body: some View {
    Card(padding: 16) {
      HStack(spacing: 12) {
        IconTile(systemName: "icloud.slash.fill", tint: Brand.blue, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(skipped.headline)
            .font(.system(size: 13, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
          Text("Download them to this Mac to include them in your next backup.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        Button("Show Files") { showingFiles = true }
          .buttonStyle(.bordered)
      }
    }
    .sheet(isPresented: $showingFiles) {
      CloudOnlyFilesSheet(skipped: skipped)
    }
  }
}

struct CloudOnlyFilesSheet: View {
  let skipped: CloudOnlySkip
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        IconTile(systemName: "icloud.slash.fill", tint: Brand.blue, size: 40)
        VStack(alignment: .leading, spacing: 4) {
          Text("Stored only in the cloud")
            .font(.system(size: 20, weight: .bold, design: .rounded))
          Text(
            "\(skipped.headline) They are not on this Mac. To back them up, this Mac must download them first."
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
          Button {
            Clipboard.copy(displayedPaths.joined(separator: "\n"))
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
          Text(displayedPaths.joined(separator: "\n"))
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(height: 200)
        .background(CardBackground())
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("To back them up")
          .font(.headline)
        Step(
          number: 1,
          text: "In Finder, Control-click the files or their folder and choose Download Now, "
            + "or Keep Downloaded to keep them on this Mac.")
        Step(
          number: 2,
          text: "Or keep all of iCloud Drive on this Mac: in System Settings, click your name, then iCloud, "
            + "then Drive, and turn off Optimize Mac Storage.")
        Text(
          "Dropbox, OneDrive, Google Drive and other cloud apps work the same way: make the files available "
            + "offline and the next backup includes them."
        )
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
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
    .frame(width: 540)
    .onEscape { dismiss() }
  }

  private var displayedPaths: [String] {
    skipped.sample.map(Format.abbreviatedPath)
  }

  private var listTitle: String {
    let hidden = skipped.count - skipped.sample.count
    return hidden > 0 ? "First \(skipped.sample.count), and \(hidden) more" : "All \(skipped.count)"
  }

  private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text("\(number).")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
        Text(text)
          .font(.system(size: 13))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

extension CloudOnlySkip {
  fileprivate var headline: String {
    let noun = sample.contains { $0.hasSuffix("/") } ? "item" : "file"
    let subject = count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    let size = bytes > 0 ? " (\(Format.bytes(bytes)))" : ""
    let verb = count == 1 ? "is stored only in the cloud and was not" : "are stored only in the cloud and were not"
    return "\(subject)\(size) \(verb) backed up."
  }
}
