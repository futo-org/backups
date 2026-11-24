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

public enum RestorePlan {
  public static let wholeVolumeName = "Macintosh HD"

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
