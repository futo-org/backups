import Darwin
import Foundation

public struct FileStatus: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case regular
    case directory
    case symbolicLink
    case other
  }

  public static let datalessFlag: UInt32 = 0x4000_0000

  public var kind: Kind
  public var flags: UInt32
  public var size: Int64
  public var device: Int32

  public init(kind: Kind, flags: UInt32 = 0, size: Int64 = 0, device: Int32 = 1) {
    self.kind = kind
    self.flags = flags
    self.size = size
    self.device = device
  }

  public var isDataless: Bool { flags & Self.datalessFlag != 0 }

  init(_ info: stat) {
    let kind: Kind =
      switch info.st_mode & S_IFMT {
      case S_IFREG: .regular
      case S_IFDIR: .directory
      case S_IFLNK: .symbolicLink
      default: .other
      }
    self.init(kind: kind, flags: info.st_flags, size: info.st_size, device: info.st_dev)
  }
}

public struct FileTreeEntry: Sendable, Equatable {
  public var name: String
  public var status: FileStatus

  public init(name: String, status: FileStatus) {
    self.name = name
    self.status = status
  }
}

public protocol FileTree: Sendable {
  func status(at path: String) -> FileStatus?
  func entries(in directory: String) -> [FileTreeEntry]?
}

public struct LocalFileTree: FileTree {
  public init() {}

  public func status(at path: String) -> FileStatus? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return FileStatus(info)
  }

  public func entries(in directory: String) -> [FileTreeEntry]? {
    let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { return nil }
    guard let stream = fdopendir(descriptor) else {
      close(descriptor)
      return nil
    }
    defer { closedir(stream) }
    var entries: [FileTreeEntry] = []
    while let entry = readdir(stream) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
        String(decoding: bytes.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
      }
      if name == "." || name == ".." {
        continue
      }
      var info = stat()
      guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
      entries.append(FileTreeEntry(name: name, status: FileStatus(info)))
    }
    return entries
  }
}
