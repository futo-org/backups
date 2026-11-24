import Darwin
import Foundation

public struct RestoreItem: Equatable, Sendable {
  public var snapshotPath: String
  public var target: URL

  public init(snapshotPath: String, target: URL) {
    self.snapshotPath = snapshotPath
    self.target = target
  }
}

public enum RestoreBatch: Equatable, Sendable {
  case folder(RestoreItem)
  case children([SnapshotEntry], of: String)

  public var name: String {
    switch self {
    case .folder(let item):
      return RestorePlan.folderName(of: item.snapshotPath)
    case .children(let children, let parent):
      return children.count == 1 ? children[0].name : RestorePlan.folderName(of: parent)
    }
  }
}

public enum RestorePlan {
  public static let wholeVolumeName = "Macintosh HD"
  static let stagingName = ".FUTO Backups Restore"

  public static func items(
    paths: [String], into target: URL,
    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
  ) -> [RestoreItem] {
    var taken = Set<String>()
    return paths.map { path in
      let base = folderName(of: path)
      var name = base
      var suffix = 2
      while taken.contains(name.lowercased()) || exists(target.appendingPathComponent(name)) {
        name = "\(base) \(suffix)"
        suffix += 1
      }
      taken.insert(name.lowercased())
      return RestoreItem(snapshotPath: path, target: target.appendingPathComponent(name))
    }
  }

  public static func claimTarget(
    for item: RestoreItem, avoiding taken: Set<String>, createDirectory: (URL) throws -> Bool
  ) throws -> URL {
    let parent = item.target.deletingLastPathComponent()
    let base = folderName(of: item.snapshotPath)
    var name = item.target.lastPathComponent
    var suffix = 2
    while true {
      let candidate = parent.appendingPathComponent(name)
      if !taken.contains(name.lowercased()), try createDirectory(candidate) {
        return candidate
      }
      name = "\(base) \(suffix)"
      suffix += 1
    }
  }

  public static func batches(for entries: [SnapshotEntry], into target: URL) -> [RestoreBatch] {
    var batches: [RestoreBatch] = []
    var childIndex: [String: Int] = [:]
    for entry in entries {
      guard let parent = entry.parentPath else {
        batches.append(
          .folder(
            RestoreItem(
              snapshotPath: entry.path, target: target.appendingPathComponent(folderName(of: entry.path)))))
        continue
      }
      if let index = childIndex[parent], case .children(let siblings, _) = batches[index] {
        batches[index] = .children(siblings + [entry], of: parent)
      } else {
        childIndex[parent] = batches.count
        batches.append(.children([entry], of: parent))
      }
    }
    return batches
  }

  public static func claimName(
    for entry: SnapshotEntry, in target: URL, avoiding taken: Set<String>, place: (URL) throws -> Bool
  ) throws -> URL {
    var number = 1
    while true {
      let name = numberedName(entry.name, number, keepingExtension: !entry.isDirectory)
      let candidate = target.appendingPathComponent(name)
      if !taken.contains(name.lowercased()), try place(candidate) {
        return candidate
      }
      number += 1
    }
  }

  public static func claimStaging(in target: URL, createDirectory: (URL) throws -> Bool) throws -> URL {
    var number = 1
    while true {
      let candidate = target.appendingPathComponent(numberedName(stagingName, number, keepingExtension: false))
      if try createDirectory(candidate) {
        return candidate
      }
      number += 1
    }
  }

  static func numberedName(_ name: String, _ number: Int, keepingExtension: Bool) -> String {
    guard number > 1 else { return name }
    let pathExtension = (name as NSString).pathExtension
    guard keepingExtension, !pathExtension.isEmpty else { return "\(name) \(number)" }
    return "\((name as NSString).deletingPathExtension) \(number).\(pathExtension)"
  }

  public static func moveExclusively(from source: URL, to destination: URL) throws -> Bool {
    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
      return true
    }
    let code = errno
    if code == EEXIST {
      return false
    }
    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }

  public static func createDirectoryExclusively(_ url: URL) throws -> Bool {
    if mkdir(url.path, 0o777) == 0 {
      return true
    }
    let code = errno
    if code == EEXIST {
      return false
    }
    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }

  static func folderName(of path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty || name == "/" ? wholeVolumeName : name
  }
}
