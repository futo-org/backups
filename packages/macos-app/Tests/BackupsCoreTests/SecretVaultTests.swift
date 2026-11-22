import BackupsCore
import Foundation
import Testing

final class RecordingSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var mainThreadFlags: [Bool] = []
  private var active = 0
  private var maxActive = 0
  private var completed = 0
  private let delay: TimeInterval

  init(delay: TimeInterval = 0) {
    self.delay = delay
  }

  func get(_ key: SecretKey) throws -> String? {
    begin()
    defer { finish() }
    return nil
  }

  func set(_ value: String, for key: SecretKey) throws {
    begin()
    finish()
  }

  func delete(_ key: SecretKey) throws {
    begin()
    finish()
  }

  var recordedMainThreadFlags: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return mainThreadFlags
  }

  var activity: (maxActive: Int, completed: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (maxActive, completed)
  }

  private func begin() {
    lock.lock()
    mainThreadFlags.append(Thread.isMainThread)
    active += 1
    maxActive = max(maxActive, active)
    lock.unlock()
    if delay > 0 {
      Thread.sleep(forTimeInterval: delay)
    }
  }

  private func finish() {
    lock.lock()
    active -= 1
    completed += 1
    lock.unlock()
  }
}

struct ThrowingSecretStore: SecretStore {
  func get(_ key: SecretKey) throws -> String? {
    throw SecretStoreError.keychain(-25300)
  }

  func set(_ value: String, for key: SecretKey) throws {
    throw SecretStoreError.keychain(-25300)
  }

  func delete(_ key: SecretKey) throws {
    throw SecretStoreError.keychain(-25300)
  }
}

@Test("vault round trips through in-memory store")
func vaultRoundTrip() async throws {
  let vault = SecretVault(store: InMemorySecretStore())
  #expect(try await vault.get(.accessToken) == nil)
  try await vault.set("token", for: .accessToken)
  #expect(try await vault.get(.accessToken) == "token")
  try await vault.set("other", for: .masterKey)
  #expect(try await vault.get(.masterKey) == "other")
  try await vault.delete(.accessToken)
  #expect(try await vault.get(.accessToken) == nil)
  #expect(try await vault.get(.masterKey) == "other")
}

@MainActor
@Test("vault never calls the store on the main thread")
func vaultNeverRunsOnMainThread() async throws {
  let store = RecordingSecretStore()
  let vault = SecretVault(store: store)
  #expect(try await vault.get(.accessToken) == nil)
  try await vault.set("token", for: .accessToken)
  try await vault.delete(.accessToken)
  let flags = store.recordedMainThreadFlags
  #expect(flags.count == 3)
  #expect(flags.allSatisfy { !$0 })
}

@Test("vault serializes concurrent calls")
func vaultSerializesConcurrentCalls() async throws {
  let store = RecordingSecretStore(delay: 0.005)
  let vault = SecretVault(store: store)
  try await withThrowingTaskGroup(of: Void.self) { group in
    for index in 0..<20 {
      group.addTask {
        try await vault.set("value-\(index)", for: .accessToken)
      }
    }
    for try await _ in group {}
  }
  let activity = store.activity
  #expect(activity.maxActive == 1)
  #expect(activity.completed == 20)
}

@Test("vault propagates store errors")
func vaultPropagatesStoreErrors() async {
  let vault = SecretVault(store: ThrowingSecretStore())
  let failure = SecretStoreError.keychain(-25300)
  await #expect(throws: failure) {
    _ = try await vault.get(.accessToken)
  }
  await #expect(throws: failure) {
    try await vault.set("token", for: .accessToken)
  }
  await #expect(throws: failure) {
    try await vault.delete(.accessToken)
  }
}
