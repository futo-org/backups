import Foundation

public enum StandardFolder: String, CaseIterable, Sendable {
  case documents = "Documents"
  case desktop = "Desktop"
  case pictures = "Pictures"
  case movies = "Movies"
  case music = "Music"
  case downloads = "Downloads"
}

public enum FolderBundle: String, CaseIterable, Identifiable, Sendable {
  case essentials
  case essentialsAndMedia
  case everything

  public var id: String { rawValue }

  public var standardFolders: [StandardFolder] {
    switch self {
    case .essentials: [.documents, .desktop]
    case .essentialsAndMedia: [.documents, .desktop, .pictures, .movies, .music]
    case .everything: []
    }
  }

  public var includesHome: Bool { self == .everything }
}

public enum FolderChoice: Hashable, Sendable {
  case home
  case standard(StandardFolder)
  case other(String)

  public func path(home: String) -> String {
    switch self {
    case .home: home
    case .standard(let folder): (home as NSString).appendingPathComponent(folder.rawValue)
    case .other(let path): path
    }
  }

  public var promptsWithoutFullDiskAccess: Bool {
    switch self {
    case .home, .standard(.documents), .standard(.desktop), .standard(.downloads): true
    case .standard, .other: false
    }
  }
}

public struct FolderSelection: Equatable, Sendable {
  public let home: String
  public private(set) var choices: [FolderChoice]
  public private(set) var selected: Set<FolderChoice> = []
  public private(set) var bundle: FolderBundle

  public init(
    home: String, bundle: FolderBundle = .essentialsAndMedia,
    isDirectory: (String) -> Bool = FolderSelection.isDirectory
  ) {
    let home = Self.normalized(home)
    self.home = home
    self.bundle = bundle
    let standard = StandardFolder.allCases.map(FolderChoice.standard)
    choices = (standard + [.home]).filter { isDirectory($0.path(home: home)) }
    apply(bundle)
  }

  public static func isDirectory(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
  }

  public mutating func apply(_ bundle: FolderBundle) {
    self.bundle = bundle
    var preset = Set(bundle.standardFolders.map(FolderChoice.standard))
    if bundle.includesHome {
      preset.insert(.home)
    }
    let others = selected.filter {
      if case .other = $0 { return true }
      return false
    }
    selected = preset.intersection(choices).union(others)
  }

  public func applying(_ bundle: FolderBundle) -> FolderSelection {
    var copy = self
    copy.apply(bundle)
    return copy
  }

  public func path(of choice: FolderChoice) -> String {
    choice.path(home: home)
  }

  public func isSelected(_ choice: FolderChoice) -> Bool {
    selected.contains(choice)
  }

  public func coveringChoice(of choice: FolderChoice) -> FolderChoice? {
    let path = path(of: choice)
    return choices.first { other in
      other != choice && selected.contains(other) && Self.isAncestor(self.path(of: other), of: path)
    }
  }

  public func isIncluded(_ choice: FolderChoice) -> Bool {
    selected.contains(choice) || coveringChoice(of: choice) != nil
  }

  public func pathsToMeasure(hasFullDiskAccess: Bool) -> [String] {
    choices.filter { hasFullDiskAccess || !$0.promptsWithoutFullDiskAccess || isIncluded($0) }.map(path(of:))
  }

  public mutating func set(_ choice: FolderChoice, selected isSelected: Bool) {
    guard choices.contains(choice) else { return }
    if isSelected {
      selected.insert(choice)
    } else {
      selected.remove(choice)
    }
  }

  public mutating func addOthers(_ paths: [String]) {
    for path in paths.map(Self.normalized) {
      if let existing = choices.first(where: { self.path(of: $0) == path }) {
        selected.insert(existing)
        continue
      }
      let choice = FolderChoice.other(path)
      choices.append(choice)
      selected.insert(choice)
    }
  }

  public var paths: [String] {
    choices.filter { selected.contains($0) && coveringChoice(of: $0) == nil }.map(path(of:))
  }

  public var canContinue: Bool { !paths.isEmpty }

  public func total(_ size: (String) -> FolderSize) -> SizeTotal {
    paths.reduce(into: SizeTotal()) { total, path in
      switch size(path) {
      case .calculating: total.isCalculating = true
      case .unavailable:
        total.isPartial = true
      case .bytes(let bytes):
        total.bytes = (total.bytes ?? 0) + bytes
      case .atLeast(let bytes):
        total.bytes = (total.bytes ?? 0) + bytes
        total.isPartial = true
      }
    }
  }

  static func normalized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  static func isAncestor(_ ancestor: String, of path: String) -> Bool {
    let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
    return path != ancestor && path.hasPrefix(prefix)
  }
}
