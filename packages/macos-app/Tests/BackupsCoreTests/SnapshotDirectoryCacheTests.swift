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
  let started = AsyncStream<Void>.makeStream()
  let entered = AsyncStream<Void>.makeStream()
  let gate = AsyncStream<Void>.makeStream()
  let cache = SnapshotDirectoryCache { path in
    started.continuation.yield()
    for await _ in gate.stream {}
    return try recorder.load(path)
  }
  var starts = started.stream.makeAsyncIterator()
  var entries = entered.stream.makeAsyncIterator()
  let first = Task { try await cache.entries(in: "/a") }
  await starts.next()
  let second = Task {
    entered.continuation.yield()
    return try await cache.entries(in: "/a")
  }
  await entries.next()
  gate.continuation.finish()
  #expect(try await first.value == second.value)
  #expect(recorder.loads == ["/a"])
}

@MainActor @Test func cancelAllStopsPendingListings() async throws {
  let started = AsyncStream<Void>.makeStream()
  let cache = SnapshotDirectoryCache { _ in
    started.continuation.yield()
    try await Task.sleep(for: .seconds(30))
    return []
  }
  let request = Task { try await cache.entries(in: "/a") }
  var starts = started.stream.makeAsyncIterator()
  await starts.next()
  cache.cancelAll()
  await #expect(throws: CancellationError.self) {
    _ = try await request.value
  }
  #expect(cache.cached("/a") == nil)
}

@MainActor @Test func cancellingADirectoryStopsOnlyItsListingAndLetsItLoadAgain() async throws {
  let slowAttempts = Counter()
  let started = AsyncStream<String>.makeStream()
  let gate = AsyncStream<Void>.makeStream()
  let cache = SnapshotDirectoryCache { path in
    started.continuation.yield(path)
    if path == "/slow" {
      slowAttempts.increment()
      if slowAttempts.value == 1 {
        try await Task.sleep(for: .seconds(30))
      }
    } else {
      for await _ in gate.stream {}
    }
    return [SnapshotEntry(name: "child", path: path + "/child", kind: .file)]
  }
  let slow = Task { try await cache.entries(in: "/slow") }
  let other = Task { try await cache.entries(in: "/other") }
  var starts = started.stream.makeAsyncIterator()
  let firstStart = await starts.next()
  let secondStart = await starts.next()
  #expect(Set([firstStart, secondStart]) == ["/slow", "/other"])
  cache.cancel("/slow")
  await #expect(throws: CancellationError.self) {
    _ = try await slow.value
  }
  #expect(cache.cached("/slow") == nil)
  gate.continuation.finish()
  #expect(try await other.value.map(\.name) == ["child"])
  #expect(try await cache.entries(in: "/slow").map(\.name) == ["child"])
  #expect(slowAttempts.value == 2)
}
