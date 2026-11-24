import Foundation

public struct SnapshotEntry: Equatable, Hashable, Sendable, Identifiable {
  public enum Kind: Equatable, Hashable, Sendable {
    case directory
    case file
    case symlink
    case other
  }

  public var name: String
  public var path: String
  public var kind: Kind
  public var size: Int64?
  public var modified: Date?

  public init(name: String, path: String, kind: Kind, size: Int64? = nil, modified: Date? = nil) {
    self.name = name
    self.path = path
    self.kind = kind
    self.size = size
    self.modified = modified
  }

  public var id: String { path }

  public var isDirectory: Bool { kind == .directory }

  public var parentPath: String? {
    SnapshotListing.parent(of: path)
  }
}

public struct SnapshotListingError: Error, Equatable, Sendable {
  public var line: String
}

public enum SnapshotListing {
  public static let rootPath = "/"

  public static func roots(of snapshotPaths: [String]) -> [SnapshotEntry] {
    sorted(
      snapshotPaths.map { path in
        SnapshotEntry(name: RestorePlan.folderName(of: path), path: path, kind: .directory)
      })
  }

  public static func parse(_ data: Data, directory: String) throws -> [SnapshotEntry] {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    var entries: [SnapshotEntry] = []
    for line in data.split(separator: UInt8(ascii: "\n")) where !line.allSatisfy(isWhitespace) {
      guard let node = try? decoder.decode(NodeLine.self, from: Data(line)) else {
        throw SnapshotListingError(line: String(decoding: line, as: UTF8.self))
      }
      guard node.messageType == "node", let name = node.name, let path = node.path,
        parent(of: path) == directory
      else { continue }
      entries.append(
        SnapshotEntry(
          name: name, path: path, kind: kind(of: node.type), size: node.size,
          modified: node.mtime.flatMap(ResticOutput.parseTimestamp)))
    }
    return sorted(entries)
  }

  public static func sorted(_ entries: [SnapshotEntry]) -> [SnapshotEntry] {
    entries.sorted { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory {
        return lhs.isDirectory
      }
      switch lhs.name.localizedStandardCompare(rhs.name) {
      case .orderedAscending: return true
      case .orderedDescending: return false
      case .orderedSame: return lhs.path < rhs.path
      }
    }
  }

  static func parent(of path: String) -> String? {
    let scalars = path.unicodeScalars
    guard path != rootPath, let slash = scalars.lastIndex(of: "/") else { return nil }
    return slash == scalars.startIndex ? rootPath : String(scalars[..<slash])
  }

  private static func kind(of type: String?) -> SnapshotEntry.Kind {
    switch type {
    case "dir": return .directory
    case "file": return .file
    case "symlink": return .symlink
    default: return .other
    }
  }

  private static func isWhitespace(_ byte: UInt8) -> Bool {
    byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\r") || byte == UInt8(ascii: "\t")
  }
}

private struct NodeLine: Decodable {
  var messageType: String?
  var name: String?
  var type: String?
  var path: String?
  var size: Int64?
  var mtime: String?
}
