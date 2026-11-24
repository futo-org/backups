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

  static func folderName(of path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty || name == "/" ? wholeVolumeName : name
  }
}
