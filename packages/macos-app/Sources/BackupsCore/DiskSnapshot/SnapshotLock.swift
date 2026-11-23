import Darwin
import Foundation

public final class SnapshotLock: @unchecked Sendable {
  private let descriptor: Int32
  private let stateLock = NSLock()
  private var held = true

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  public static func acquire(at url: URL) -> SnapshotLock? {
    let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      close(descriptor)
      return nil
    }
    return SnapshotLock(descriptor: descriptor)
  }

  public func release() {
    stateLock.withLock {
      guard held else { return }
      held = false
      flock(descriptor, LOCK_UN)
      close(descriptor)
    }
  }

  deinit {
    release()
  }
}
