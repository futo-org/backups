import Darwin
import Foundation
import Synchronization

public enum FolderSize: Equatable, Sendable {
  case calculating
  case unavailable
  case bytes(Int64)
}

public struct SizeTotal: Equatable, Sendable {
  public var bytes: Int64 = 0
  public var isCalculating = false
  public var isPartial = false

  public init(bytes: Int64 = 0, isCalculating: Bool = false, isPartial: Bool = false) {
    self.bytes = bytes
    self.isCalculating = isCalculating
    self.isPartial = isPartial
  }
}

public struct FolderSizer: Sendable {
  public let excludes: [String]
  private let queue: DispatchQueue

  public init(
    excludes: [String],
    queue: DispatchQueue = DispatchQueue(label: "org.futo.backups.mac.sizes", qos: .utility, attributes: .concurrent)
  ) {
    self.excludes = excludes
    self.queue = queue
  }

  public func size(of path: String) async throws -> Int64? {
    try Task.checkCancellation()
    let cancelled = CancellationFlag()
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Int64?, Never>) in
        queue.async {
          continuation.resume(returning: measure(path, isCancelled: cancelled.isSet))
        }
      }
    } onCancel: {
      cancelled.set()
    }
    try Task.checkCancellation()
    return result
  }

  public func measure(_ path: String, isCancelled: () -> Bool = { false }) -> Int64? {
    guard FolderSelection.isDirectory(path) else { return nil }
    return DirectoryWalk.totalBytes(under: path, isExcluded: isExcluded, isCancelled: isCancelled)
  }

  public func isExcluded(_ path: String) -> Bool {
    excludes.contains { pattern in
      if pattern.hasPrefix("/") {
        return fnmatch(pattern, path, FNM_PATHNAME) == 0
      }
      let relative = pattern.hasPrefix("**/") ? String(pattern.dropFirst(3)) : pattern
      return fnmatch("*/" + relative, path, 0) == 0
    }
  }
}

private final class CancellationFlag: Sendable {
  private let value = Atomic<Bool>(false)

  func set() {
    value.store(true, ordering: .relaxed)
  }

  func isSet() -> Bool {
    value.load(ordering: .relaxed)
  }
}
