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

public struct RestoreIncomplete: Error {
  public var restored: [URL]
  public var leftoverStaging: URL?
  public var cause: any Error

  public init(restored: [URL], leftoverStaging: URL? = nil, cause: any Error) {
    self.restored = restored
    self.leftoverStaging = leftoverStaging
    self.cause = cause
  }
}

struct RestoredItems {
  private(set) var urls: [URL] = []
  private(set) var names: Set<String> = []

  mutating func append(_ url: URL) {
    urls.append(url)
    names.insert(RestorePlan.nameKey(url.lastPathComponent))
  }
}

public enum RestorePlan {
  public static let wholeVolumeName = "Macintosh HD"
  static let stagingName = ".FUTO Backups Restore"
  static let maxNameLength = 255
  public static let argumentBudget = 256 * 1024

  public static func items(
    paths: [String], into target: URL,
    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
  ) -> [RestoreItem] {
    var taken = Set<String>()
    return paths.map { path in
      let base = folderName(of: path)
      var name = base
      var suffix = 2
      while taken.contains(nameKey(name)) || exists(target.appendingPathComponent(name)) {
        name = numberedName(base, suffix, keepingExtension: false)
        suffix += 1
      }
      taken.insert(nameKey(name))
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
      if !taken.contains(nameKey(name)), try createDirectory(candidate) {
        return candidate
      }
      name = numberedName(base, suffix, keepingExtension: false)
      suffix += 1
    }
  }

  public static func batches(
    for entries: [SnapshotEntry], into target: URL, argumentBudget: Int = argumentBudget
  ) -> [RestoreBatch] {
    var slots: [RestoreBatch] = []
    var groups: [String: [SnapshotEntry]] = [:]
    for entry in entries {
      guard let parent = entry.parentPath else {
        slots.append(
          .folder(
            RestoreItem(
              snapshotPath: entry.path, target: target.appendingPathComponent(folderName(of: entry.path)))))
        continue
      }
      if groups[parent] == nil {
        slots.append(.children([], of: parent))
      }
      groups[parent, default: []].append(entry)
    }
    return slots.flatMap { slot -> [RestoreBatch] in
      guard case .children(_, let parent) = slot, let children = groups[parent] else { return [slot] }
      return stagingGroups(children, argumentBudget: argumentBudget).map { .children($0, of: parent) }
    }
  }

  private static func stagingGroups(_ children: [SnapshotEntry], argumentBudget: Int) -> [[SnapshotEntry]] {
    var groups: [[SnapshotEntry]] = []
    var current: [SnapshotEntry] = []
    var names: Set<String> = []
    var bytes = 0
    for child in children {
      let size = includeArgumentBytes(child.name)
      if !current.isEmpty, names.contains(nameKey(child.name)) || bytes + size > argumentBudget {
        groups.append(current)
        current = []
        names = []
        bytes = 0
      }
      current.append(child)
      names.insert(nameKey(child.name))
      bytes += size
    }
    if !current.isEmpty {
      groups.append(current)
    }
    return groups
  }

  private static func includeArgumentBytes(_ name: String) -> Int {
    let pointers = 2 * MemoryLayout<UnsafePointer<CChar>>.size
    return pointers + "--include".utf8.count + 1 + ResticCommand.childPattern(name).utf8.count + 1
  }

  public static func claimName(
    for entry: SnapshotEntry, in target: URL, avoiding taken: Set<String>, place: (URL) throws -> Bool
  ) throws -> URL {
    var number = 1
    while true {
      let name = numberedName(entry.name, number, keepingExtension: !entry.isDirectory)
      let candidate = target.appendingPathComponent(name)
      if !taken.contains(nameKey(name)), try place(candidate) {
        return candidate
      }
      number += 1
    }
  }

  public static func claimStaging(
    in target: URL, avoiding restoring: Set<String> = [], createDirectory: (URL) throws -> Bool
  ) throws -> URL {
    var number = 1
    while true {
      let name = numberedName(stagingName, number, keepingExtension: false)
      let candidate = target.appendingPathComponent(name)
      if !restoring.contains(nameKey(name)), try createDirectory(candidate) {
        return candidate
      }
      number += 1
    }
  }

  static func numberedName(_ name: String, _ number: Int, keepingExtension: Bool) -> String {
    guard number > 1 else { return name }
    let pathExtension = (name as NSString).pathExtension
    let keepsExtension = keepingExtension && !pathExtension.isEmpty
    var stem = keepsExtension ? (name as NSString).deletingPathExtension : name
    let suffix = keepsExtension ? " \(number).\(pathExtension)" : " \(number)"
    while !stem.isEmpty, nameLength(stem + suffix) > maxNameLength {
      stem.removeLast()
    }
    return stem + suffix
  }

  static func nameLength(_ name: String) -> Int {
    name.decomposedStringWithCanonicalMapping.utf16.count
  }

  static func nameKey(_ name: String) -> String {
    name.lowercased()
  }

  public static func moveExclusively(from source: URL, to destination: URL) throws -> Bool {
    if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
      return true
    }
    var code = errno
    if code == EACCES, let mode = directoryMode(source), mode & S_IWUSR == 0 {
      chmod(source.path, mode | S_IWUSR)
      if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
        chmod(destination.path, mode)
        return true
      }
      code = errno
      chmod(source.path, mode)
    }
    if code == EEXIST {
      return false
    }
    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }

  private static func directoryMode(_ url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    return info.st_mode & ~S_IFMT
  }

  public static func createDirectoryExclusively(_ url: URL) throws -> Bool {
    try makeDirectoryExclusively(url, mode: 0o777)
  }

  public static func createStagingExclusively(_ url: URL) throws -> Bool {
    try makeDirectoryExclusively(url, mode: 0o700)
  }

  private static func makeDirectoryExclusively(_ url: URL, mode: mode_t) throws -> Bool {
    if mkdir(url.path, mode) == 0 {
      return true
    }
    let code = errno
    if code == EEXIST {
      return false
    }
    throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
  }

  public static func removeStaging(_ url: URL) throws {
    let fileManager = FileManager.default
    allowOwnerAccess(url)
    if let contents = fileManager.enumerator(at: url, includingPropertiesForKeys: nil) {
      for case let item as URL in contents {
        allowOwnerAccess(item)
      }
    }
    try fileManager.removeItem(at: url)
  }

  private static func allowOwnerAccess(_ url: URL) {
    if let mode = directoryMode(url), mode & S_IRWXU != S_IRWXU {
      chmod(url.path, mode | S_IRWXU)
    }
  }

  static func folderName(of path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty || name == "/" ? wholeVolumeName : name
  }
}
