import Darwin
import Foundation
import Testing

@testable import BackupsCore

private func lockURL() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
}

@Test func acquireSucceedsAndBlocksSecondAcquire() throws {
  let url = lockURL()
  defer { try? FileManager.default.removeItem(at: url) }
  let first = try #require(SnapshotLock.acquire(at: url))
  #expect(SnapshotLock.acquire(at: url) == nil)
  first.release()
}

@Test func acquireSucceedsAfterRelease() throws {
  let url = lockURL()
  defer { try? FileManager.default.removeItem(at: url) }
  let first = try #require(SnapshotLock.acquire(at: url))
  first.release()
  let second = try #require(SnapshotLock.acquire(at: url))
  #expect(SnapshotLock.acquire(at: url) == nil)
  second.release()
}

@Test func releaseTwiceIsSafe() throws {
  let url = lockURL()
  defer { try? FileManager.default.removeItem(at: url) }
  let lock = try #require(SnapshotLock.acquire(at: url))
  lock.release()
  lock.release()
  let reacquired = try #require(SnapshotLock.acquire(at: url))
  reacquired.release()
}

@Test func lockFileHasPrivatePermissions() throws {
  let url = lockURL()
  defer { try? FileManager.default.removeItem(at: url) }
  let lock = try #require(SnapshotLock.acquire(at: url))
  defer { lock.release() }
  var info = stat()
  #expect(stat(url.path, &info) == 0)
  #expect(info.st_mode & 0o777 == 0o600)
}

@Test func droppingReferenceReleasesLock() throws {
  let url = lockURL()
  defer { try? FileManager.default.removeItem(at: url) }
  var lock: SnapshotLock? = try #require(SnapshotLock.acquire(at: url))
  #expect(SnapshotLock.acquire(at: url) == nil)
  lock = nil
  let reacquired = try #require(SnapshotLock.acquire(at: url))
  reacquired.release()
}
