import BackupsCore
import SwiftUI

struct StatusSummary {
  enum Action {
    case backUp
    case addFolders
    case cancel
    case none
  }

  var title: String
  var subtitle: String
  var compactSubtitle: String?
  var symbol: String
  var tint: Color
  var progress: Double?
  var busy = false
  var action: Action
  var menuBarSymbol: String

  @MainActor
  init(model: AppModel, progress: BackupProgress?) {
    switch model.activity {
    case .backingUp where (progress?.percentDone ?? 0) >= 0.999:
      self.init(
        title: "Finishing backup", subtitle: "Uploading the last changes…", symbol: "arrow.up", tint: Brand.blue,
        busy: true, action: .cancel, menuBarSymbol: "arrow.clockwise.icloud")
      return
    case .backingUp:
      self.init(
        title: "Backing up", subtitle: progress.map(Self.transferred) ?? "", symbol: "arrow.up", tint: Brand.blue,
        progress: progress?.percentDone ?? 0, action: .cancel, menuBarSymbol: "arrow.clockwise.icloud")
      return
    case .preparing:
      self.init(
        title: "Preparing backup", subtitle: "Looking for changes in your folders…", symbol: "magnifyingglass",
        tint: Brand.blue, busy: true, action: .cancel, menuBarSymbol: "arrow.clockwise.icloud")
      return
    case .finishing(let step):
      self.init(
        title: "Finishing backup",
        subtitle: step == .removingDiskSnapshot
          ? "Removing the disk snapshot…" : "Checking for files kept only in the cloud…",
        symbol: "checkmark", tint: Brand.blue, busy: true, action: .none, menuBarSymbol: "arrow.clockwise.icloud")
      return
    case .pruning:
      self.init(
        title: "Tidying up", subtitle: "Removing snapshots older than 60 days…", symbol: "sparkles",
        tint: Brand.blue, busy: true, action: .none, menuBarSymbol: "arrow.clockwise.icloud")
      return
    case .restoring:
      self.init(
        title: "Restoring", subtitle: "Bringing your files back…", symbol: "arrow.down", tint: Brand.blue,
        busy: true, action: .cancel, menuBarSymbol: "arrow.down.circle")
      return
    case .changingRecoveryKey:
      self.init(
        title: "Changing recovery key", subtitle: "Updating the key for this Mac's backup…", symbol: "key.fill",
        tint: Brand.blue, busy: true, action: .none, menuBarSymbol: "arrow.clockwise.icloud")
      return
    case nil:
      break
    }
    if model.config.folders.isEmpty {
      self.init(
        title: "Choose what to back up", subtitle: "Add the folders you want to keep safe.",
        symbol: "folder.badge.plus", tint: Brand.blue, action: .addFolders, menuBarSymbol: "icloud")
      return
    }
    guard let lastRun = model.config.lastRun else {
      let count = model.config.folders.count
      self.init(
        title: "Ready for your first backup",
        subtitle: "\(count) \(count == 1 ? "folder" : "folders") selected. Everything is encrypted on this Mac.",
        symbol: "icloud.and.arrow.up", tint: Brand.blue, action: .backUp, menuBarSymbol: "icloud")
      return
    }
    let when = Format.relative(lastRun.finishedAt, inSentence: true)
    switch lastRun.status {
    case .complete:
      let protected = model.snapshots.first.map { "\(Format.bytes($0.totalBytesProcessed)) protected" }
      self.init(
        title: "Your files are protected",
        subtitle: (["Last backup \(when)"] + [protected].compactMap { $0 }).joined(separator: " · "),
        symbol: "checkmark", tint: .green, action: .backUp, menuBarSymbol: "lock.icloud")
      compactSubtitle = protected ?? "All folders backed up"
    case .warn:
      self.init(
        title: "Backed up with warnings", subtitle: lastRun.message ?? "Some files could not be read.",
        symbol: "exclamationmark", tint: .orange, action: .backUp, menuBarSymbol: "exclamationmark.icloud")
    case .failed, .incomplete:
      self.init(
        title: "Last backup failed", subtitle: lastRun.message ?? "Try again, or check your connection.",
        symbol: "xmark", tint: .red, action: .backUp, menuBarSymbol: "exclamationmark.icloud")
    case .cancelled, .skipped:
      self.init(
        title: "Backup cancelled", subtitle: "Stopped \(when).", symbol: "pause",
        tint: .secondary, action: .backUp, menuBarSymbol: "icloud")
    }
  }

  @MainActor
  private static func transferred(_ progress: BackupProgress) -> String {
    var parts = ["\(Format.bytes(progress.bytesDone)) of \(Format.bytes(progress.totalBytes))"]
    if let seconds = progress.secondsRemaining { parts.append(Format.duration(seconds)) }
    return parts.joined(separator: " · ")
  }

  private init(
    title: String, subtitle: String, symbol: String, tint: Color, progress: Double? = nil, busy: Bool = false,
    action: Action, menuBarSymbol: String
  ) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.tint = tint
    self.progress = progress
    self.busy = busy
    self.action = action
    self.menuBarSymbol = menuBarSymbol
  }
}
