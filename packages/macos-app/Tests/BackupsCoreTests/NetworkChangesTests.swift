import Foundation
import Testing

@testable import BackupsCore

private let wifi = NetworkPath(isSatisfied: true, interfaces: ["en0"])
private let wifiAndEthernet = NetworkPath(isSatisfied: true, interfaces: ["en0", "en7"])
private let ethernet = NetworkPath(isSatisfied: true, interfaces: ["en7"])
private let offline = NetworkPath(isSatisfied: false, interfaces: [])

@Test(
  "invalidatesConnections table",
  arguments: [
    (wifi, wifi, false),
    (wifi, ethernet, true),
    (wifiAndEthernet, ethernet, true),
    (wifi, wifiAndEthernet, true),
    (offline, wifi, true),
    (wifi, offline, false),
    (offline, offline, false),
  ])
func invalidatesConnections(previous: NetworkPath, current: NetworkPath, expected: Bool) {
  #expect(current.invalidatesConnections(since: previous) == expected)
}

private final class ManualSleeper: @unchecked Sendable {
  private let lock = NSLock()
  private var waiting: [Int: CheckedContinuation<Void, any Error>] = [:]
  private var cancelled: Set<Int> = []
  private var started = 0
  private var nextId = 0

  var sleepCount: Int {
    lock.withLock { started }
  }

  var waitingCount: Int {
    lock.withLock { waiting.count }
  }

  func sleep(_ duration: Duration) async throws {
    let id = lock.withLock { () -> Int in
      nextId += 1
      started += 1
      return nextId
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let alreadyCancelled = lock.withLock { () -> Bool in
          if cancelled.contains(id) { return true }
          waiting[id] = continuation
          return false
        }
        if alreadyCancelled {
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
        cancelled.insert(id)
        return waiting.removeValue(forKey: id)
      }
      continuation?.resume(throwing: CancellationError())
    }
  }

  func wakeAll() {
    let continuations = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
      let all = Array(waiting.values)
      waiting = [:]
      return all
    }
    for continuation in continuations {
      continuation.resume()
    }
  }
}

private struct Harness {
  let sleeper = ManualSleeper()
  let paths: AsyncStream<NetworkPath>.Continuation
  let changes: AsyncStream<Void>

  init() {
    let (stream, continuation) = AsyncStream<NetworkPath>.makeStream()
    paths = continuation
    let sleeper = sleeper
    changes = NetworkChanges.changes(in: stream, debounce: .seconds(1), sleep: { try await sleeper.sleep($0) })
  }

  func waitFor(sleeps: Int, waiting: Int) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while sleeper.sleepCount != sleeps || sleeper.waitingCount != waiting, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(sleeper.sleepCount == sleeps)
    #expect(sleeper.waitingCount == waiting)
  }
}

@Test func aBurstOfPathUpdatesReportsOneChange() async throws {
  let harness = Harness()
  var changes = harness.changes.makeAsyncIterator()
  harness.paths.yield(wifi)
  harness.paths.yield(wifiAndEthernet)
  harness.paths.yield(ethernet)
  await harness.waitFor(sleeps: 2, waiting: 1)
  harness.sleeper.wakeAll()
  #expect(await changes.next() != nil)
  harness.paths.finish()
  #expect(await changes.next() == nil)
}

@Test func theFirstPathIsOnlyABaseline() async throws {
  let harness = Harness()
  var changes = harness.changes.makeAsyncIterator()
  harness.paths.yield(ethernet)
  harness.paths.yield(ethernet)
  harness.paths.finish()
  #expect(await changes.next() == nil)
  #expect(harness.sleeper.sleepCount == 0)
}

@Test func goingOfflineDropsThePendingChangeAndReconnectingReportsOne() async throws {
  let harness = Harness()
  var changes = harness.changes.makeAsyncIterator()
  harness.paths.yield(wifi)
  harness.paths.yield(wifiAndEthernet)
  await harness.waitFor(sleeps: 1, waiting: 1)
  harness.paths.yield(offline)
  await harness.waitFor(sleeps: 1, waiting: 0)
  harness.paths.yield(ethernet)
  await harness.waitFor(sleeps: 2, waiting: 1)
  harness.sleeper.wakeAll()
  #expect(await changes.next() != nil)
  harness.paths.finish()
  #expect(await changes.next() == nil)
}

@Test func stoppingTheChangesStopsWatchingPaths() async throws {
  let terminated = OnceFlag()
  let (paths, continuation) = AsyncStream<NetworkPath>.makeStream()
  continuation.onTermination = { _ in terminated.set() }
  let changes = NetworkChanges.changes(in: paths, debounce: .seconds(1), sleep: { _ in })
  let consumer = Task {
    for await _ in changes {}
  }
  consumer.cancel()
  await consumer.value
  let deadline = ContinuousClock.now + .seconds(5)
  while !terminated.isSet, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(terminated.isSet)
}
