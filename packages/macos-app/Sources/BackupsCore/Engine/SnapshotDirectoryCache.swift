import Foundation

@MainActor
public final class SnapshotDirectoryCache {
  private let load: @Sendable (String) async throws -> [SnapshotEntry]
  private var loaded: [String: [SnapshotEntry]] = [:]
  private var pending: [String: Task<[SnapshotEntry], any Error>] = [:]

  public init(load: @escaping @Sendable (String) async throws -> [SnapshotEntry]) {
    self.load = load
  }

  public func cached(_ path: String) -> [SnapshotEntry]? {
    loaded[path]
  }

  public func entries(in path: String) async throws -> [SnapshotEntry] {
    if let entries = loaded[path] {
      return entries
    }
    let task: Task<[SnapshotEntry], any Error>
    if let existing = pending[path] {
      task = existing
    } else {
      let load = load
      task = Task { try await load(path) }
      pending[path] = task
    }
    defer {
      if pending[path] == task {
        pending[path] = nil
      }
    }
    let entries = try await task.value
    loaded[path] = entries
    return entries
  }

  public func cancel(_ path: String) {
    pending.removeValue(forKey: path)?.cancel()
  }

  public func cancelAll() {
    for task in pending.values {
      task.cancel()
    }
    pending = [:]
  }
}
