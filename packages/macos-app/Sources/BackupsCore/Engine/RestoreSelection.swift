import Foundation

public struct RestoreSelection: Equatable, Sendable {
  public private(set) var entries: [SnapshotEntry] = []

  public init() {}

  public var count: Int { entries.count }

  public var isEmpty: Bool { entries.isEmpty }

  public func contains(_ entry: SnapshotEntry) -> Bool {
    entries.contains { $0.path == entry.path }
  }

  public func isCoveredByFolder(_ entry: SnapshotEntry) -> Bool {
    entries.contains { $0.isDirectory && Self.isDescendant(entry.path, of: $0.path) }
  }

  public func isIncluded(_ entry: SnapshotEntry) -> Bool {
    contains(entry) || isCoveredByFolder(entry)
  }

  public mutating func toggle(_ entry: SnapshotEntry) {
    guard !isCoveredByFolder(entry) else { return }
    if contains(entry) {
      entries.removeAll { $0.path == entry.path }
      return
    }
    if entry.isDirectory {
      entries.removeAll { Self.isDescendant($0.path, of: entry.path) }
    }
    entries.append(entry)
  }

  public mutating func removeAll() {
    entries = []
  }

  static func isDescendant(_ path: String, of folder: String) -> Bool {
    path != folder && path.hasPrefix(folder == SnapshotListing.rootPath ? folder : folder + "/")
  }
}
