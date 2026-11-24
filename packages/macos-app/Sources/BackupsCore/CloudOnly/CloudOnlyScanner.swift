import Foundation

public struct CloudOnlySkip: Codable, Equatable, Sendable {
  public static let sampleLimit = 200

  public var count: Int
  public var bytes: Int64
  public var sample: [String]

  public init(count: Int = 0, bytes: Int64 = 0, sample: [String] = []) {
    self.count = count
    self.bytes = bytes
    self.sample = sample
  }

  public var telemetrySizeBucket: String {
    let megabyte: Int64 = 1_000_000
    switch bytes {
    case 0: return "0"
    case ..<(100 * megabyte): return "<100MB"
    case ..<(1_000 * megabyte): return "<1GB"
    case ..<(10_000 * megabyte): return "<10GB"
    case ..<(100_000 * megabyte): return "<100GB"
    default: return ">=100GB"
    }
  }
}

public enum CloudOnlyError: Error, Equatable, Sendable, CustomStringConvertible {
  case everyFolderIsCloudOnly

  public var description: String {
    "The selected folders are stored only in the cloud, so there is nothing on this Mac to back up."
  }
}

public protocol CloudOnlyScanning: Sendable {
  func isCloudOnly(_ path: String) -> Bool
  func scan(folders: [String], excludes: [String]) async -> CloudOnlySkip?
}

public struct NoCloudOnlyScan: CloudOnlyScanning {
  public init() {}

  public func isCloudOnly(_ path: String) -> Bool { false }

  public func scan(folders: [String], excludes: [String]) async -> CloudOnlySkip? { nil }
}

public struct CloudOnlyScanner: CloudOnlyScanning {
  private struct Directory {
    var path: String
    var components: [ExcludePattern.Component]
  }

  private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
      lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
      lock.withLock { cancelled }
    }
  }

  public var tree: any FileTree
  public var sampleLimit: Int

  public init(tree: any FileTree = LocalFileTree(), sampleLimit: Int = CloudOnlySkip.sampleLimit) {
    self.tree = tree
    self.sampleLimit = sampleLimit
  }

  public func isCloudOnly(_ path: String) -> Bool {
    tree.status(at: path)?.isDataless == true
  }

  public func scan(folders: [String], excludes: [String]) async -> CloudOnlySkip? {
    let flag = CancellationFlag()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<CloudOnlySkip?, Never>) in
        DispatchQueue.global(qos: .background).async {
          continuation.resume(returning: walk(folders: folders, excludes: excludes) { flag.isCancelled })
        }
      }
    } onCancel: {
      flag.cancel()
    }
  }

  public func walk(folders: [String], excludes: [String], isCancelled: () -> Bool) -> CloudOnlySkip? {
    let patterns = excludes.compactMap(ExcludePattern.init)
    var skip = CloudOnlySkip()
    func record(_ path: String, _ status: FileStatus) {
      skip.count += 1
      if status.kind == .directory {
        if skip.sample.count < sampleLimit {
          skip.sample.append(path + "/")
        }
        return
      }
      skip.bytes += status.size
      if skip.sample.count < sampleLimit {
        skip.sample.append(path)
      }
    }
    for folder in folders {
      let root = ExcludePattern.cleanPath(folder)
      guard !patterns.contains(where: { $0.matches(root) }), let rootStatus = tree.status(at: root) else {
        continue
      }
      if rootStatus.isDataless {
        record(root, rootStatus)
        continue
      }
      guard rootStatus.kind == .directory else { continue }
      var pending = [Directory(path: root, components: ExcludePattern.components(of: root))]
      while let directory = pending.popLast() {
        if isCancelled() {
          return nil
        }
        guard let entries = tree.entries(in: directory.path) else { continue }
        for entry in entries {
          let kind = entry.status.kind
          guard kind == .regular || kind == .directory else { continue }
          var components = directory.components
          components.append(Array(entry.name.unicodeScalars))
          if patterns.contains(where: { $0.matches(components: components, endAnchored: true) }) {
            continue
          }
          let path = directory.path == "/" ? "/" + entry.name : directory.path + "/" + entry.name
          if entry.status.isDataless {
            record(path, entry.status)
          } else if kind == .directory && entry.status.device == rootStatus.device {
            pending.append(Directory(path: path, components: components))
          }
        }
      }
    }
    skip.sample.sort()
    return skip
  }
}
