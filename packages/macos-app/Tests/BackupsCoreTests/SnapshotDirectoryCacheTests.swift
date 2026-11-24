import Foundation
import Testing

@testable import BackupsCore

private final class LoadRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var paths: [String] = []
  private var failures: Int

  init(failures: Int = 0) {
    self.failures = failures
  }

  var loads: [String] {
    lock.withLock { paths }
  }

  func load(_ path: String) throws -> [SnapshotEntry] {
    try lock.withLock {
      paths.append(path)
      if failures > 0 {
        failures -= 1
        throw POSIXError(.EIO)
      }
      return [SnapshotEntry(name: "child", path: path + "/child", kind: .file)]
    }
  }
}

@MainActor @Test func eachDirectoryIsListedOnceAndThenServedFromTheCache() async throws {
  let recorder = LoadRecorder()
  let cache = SnapshotDirectoryCache { try recorder.load($0) }
  #expect(cache.cached("/a") == nil)
  let first = try await cache.entries(in: "/a")
  let again = try await cache.entries(in: "/a")
  _ = try await cache.entries(in: "/b")
  #expect(first == again)
  #expect(cache.cached("/a") == first)
  #expect(recorder.loads == ["/a", "/b"])
}

@MainActor @Test func failedListingsAreRetried() async throws {
  let recorder = LoadRecorder(failures: 1)
  let cache = SnapshotDirectoryCache { try recorder.load($0) }
  await #expect(throws: POSIXError(.EIO)) {
    _ = try await cache.entries(in: "/a")
  }
  #expect(cache.cached("/a") == nil)
  #expect(try await cache.entries(in: "/a").map(\.name) == ["child"])
  #expect(recorder.loads == ["/a", "/a"])
}

@MainActor @Test func concurrentRequestsShareOneListing() async throws {
  let recorder = LoadRecorder()
  let gate = AsyncStream<Void>.makeStream()
  let cache = SnapshotDirectoryCache { path in
    for await _ in gate.stream { break }
    return try recorder.load(path)
  }
  async let first = cache.entries(in: "/a")
  async let second = cache.entries(in: "/a")
  try await Task.sleep(for: .milliseconds(20))
  gate.continuation.yield()
  #expect(try await first == second)
  #expect(recorder.loads == ["/a"])
}

@MainActor @Test func cancelAllStopsPendingListings() async throws {
  let cache = SnapshotDirectoryCache { _ in
    try await Task.sleep(for: .seconds(30))
    return []
  }
  let request = Task { try await cache.entries(in: "/a") }
  try await Task.sleep(for: .milliseconds(20))
  cache.cancelAll()
  await #expect(throws: CancellationError.self) {
    _ = try await request.value
  }
  #expect(cache.cached("/a") == nil)
}
