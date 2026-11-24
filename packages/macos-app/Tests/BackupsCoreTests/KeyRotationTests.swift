import Foundation
import Testing

@testable import BackupsCore

private let oldMasterKey = testMasterKey
private let newMasterKey = String(repeating: "f0e1d2c3b4a5968778695a4b3c2d1e0f", count: 2)
private let otherMasterKey = String(repeating: "0123456789abcdef", count: 4)

private func password(_ masterKey: String, repositoryId: String = "repo-1") -> String {
  (try? RepositoryKeys.password(masterKey: masterKey, repositoryId: repositoryId)) ?? ""
}

struct RepositoryKey: Equatable, Sendable {
  var id: String
  var password: String
}

struct PasswordFileObservation: Equatable, Sendable {
  var path: String
  var contents: String
  var filePermissions: Int?
  var directoryPermissions: Int?
}

final class FakeKeyRepository: ResticExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var keys: [RepositoryKey]
  private var nextId = 0
  private var recorded: [ResticInvocation] = []
  private var observed: [PasswordFileObservation] = []
  private var overrides: [String: ResticScript] = [:]
  private var addedPassword: String?
  private var hook: (@Sendable (String) -> Void)?
  private var gatedCommand: String?
  private var gateWaits: [CheckedContinuation<Void, Never>] = []

  init(keys: [RepositoryKey]) {
    self.keys = keys
  }

  static func command(of invocation: ResticInvocation) -> String {
    invocation.arguments.prefix { $0 != "--json" }.joined(separator: " ")
  }

  var currentKeys: [RepositoryKey] {
    lock.withLock { keys }
  }

  var invocations: [ResticInvocation] {
    lock.withLock { recorded }.filter { Self.command(of: $0) != "version" }
  }

  var commands: [String] {
    invocations.map(Self.command(of:))
  }

  var passwordFiles: [PasswordFileObservation] {
    lock.withLock { observed }
  }

  func override(_ command: String, with script: ResticScript?) {
    lock.withLock { overrides[command] = script }
  }

  func addKeysWithPassword(_ value: String) {
    lock.withLock { addedPassword = value }
  }

  func setHook(_ value: @escaping @Sendable (String) -> Void) {
    lock.withLock { hook = value }
  }

  func gate(_ command: String) {
    lock.withLock { gatedCommand = command }
  }

  func release() {
    let waits = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      gatedCommand = nil
      let waits = gateWaits
      gateWaits = []
      return waits
    }
    for wait in waits {
      wait.resume()
    }
  }

  func run(_ invocation: ResticInvocation, onLine: @escaping @Sendable (String) -> Void) async throws
    -> ResticResult
  {
    let command = Self.command(of: invocation)
    let (hook, gated) = lock.withLock { () -> ((@Sendable (String) -> Void)?, Bool) in
      recorded.append(invocation)
      return (self.hook, gatedCommand == command)
    }
    if gated {
      await withCheckedContinuation { (wait: CheckedContinuation<Void, Never>) in
        lock.withLock { gateWaits.append(wait) }
      }
    }
    hook?("before \(command)")
    let result = try lock.withLock { try execute(command, invocation) }
    hook?("after \(command)")
    return result
  }

  private func execute(_ command: String, _ invocation: ResticInvocation) throws -> ResticResult {
    if let script = overrides[command] {
      if let error = script.error {
        throw error
      }
      return ResticResult(exitCode: script.exitCode, stdout: Data(script.stdout.utf8), stderr: script.stderr)
    }
    if command == "version" {
      return success(#"{"version":"0.19.1+futo.3"}"#)
    }
    guard let opening = keys.first(where: { $0.password == invocation.environment["RESTIC_PASSWORD"] }) else {
      return failure(code: ResticExitCode.wrongPassword, "Fatal: wrong password or no key found")
    }
    switch command {
    case "cat config":
      return success("{}")
    case "key list":
      let entries = keys.map { #"{"current":\#($0.id == opening.id),"id":"\#($0.id)"}"# }
      return success("[" + entries.joined(separator: ",") + "]")
    case "key add":
      guard let path = argumentAfter(invocation.arguments, "--new-password-file") else {
        return failure(code: 1, "no new password file")
      }
      let file = URL(fileURLWithPath: path)
      let contents = try String(contentsOf: file, encoding: .utf8)
      observed.append(
        PasswordFileObservation(
          path: path, contents: contents,
          filePermissions: try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int,
          directoryPermissions: try FileManager.default.attributesOfItem(
            atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int))
      nextId += 1
      keys.append(RepositoryKey(id: "key-added-\(nextId)", password: addedPassword ?? contents))
      return success("saved new key with ID key-added-\(nextId)")
    case "key remove":
      let id = invocation.arguments.last ?? ""
      if id == opening.id {
        return failure(code: 1, "refusing to remove key currently used to access repository")
      }
      guard keys.contains(where: { $0.id == id }) else {
        return failure(code: 1, "no matching ID found for prefix \"\(id)\"")
      }
      keys.removeAll { $0.id == id }
      return success("")
    default:
      return failure(code: 1, "unexpected command \(command)")
    }
  }

  private func success(_ stdout: String) -> ResticResult {
    ResticResult(exitCode: ResticExitCode.success, stdout: Data(stdout.utf8), stderr: "")
  }

  private func failure(code: Int32, _ message: String) -> ResticResult {
    ResticResult(
      exitCode: code, stdout: Data(),
      stderr: #"{"message_type":"exit_error","code":\#(code),"message":"\#(message)"}"#)
  }
}

final class HookedSecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private let inner: InMemorySecretStore
  private var hook: (@Sendable (String) -> Void)?
  private var failingKey: SecretKey?

  init(_ values: [SecretKey: String]) {
    inner = InMemorySecretStore(values)
  }

  func setHook(_ value: @escaping @Sendable (String) -> Void) {
    lock.withLock { hook = value }
  }

  func failWrites(to key: SecretKey) {
    lock.withLock { failingKey = key }
  }

  var values: [SecretKey: String] {
    var result: [SecretKey: String] = [:]
    for key in SecretKey.allCases {
      result[key] = try? inner.get(key)
    }
    return result
  }

  func get(_ key: SecretKey) throws -> String? {
    try inner.get(key)
  }

  func set(_ value: String, for key: SecretKey) throws {
    let (hook, failing) = lock.withLock { (self.hook, failingKey == key) }
    if failing {
      throw SecretStoreError.keychain(-25293)
    }
    try inner.set(value, for: key)
    hook?("set \(key.rawValue)")
  }

  func delete(_ key: SecretKey) throws {
    let hook = lock.withLock { self.hook }
    try inner.delete(key)
    hook?("delete \(key.rawValue)")
  }
}

private final class CrashCapture: @unchecked Sendable {
  struct State {
    var secrets: [SecretKey: String]
    var keys: [RepositoryKey]
  }

  private let lock = NSLock()
  private var captured: State?

  func capture(_ state: @autoclosure () -> State) {
    lock.withLock {
      if captured == nil {
        captured = state()
      }
    }
  }

  var state: State? {
    lock.withLock { captured }
  }
}

private struct KeyFixture {
  var engine: BackupEngine
  var repository: FakeKeyRepository
  var secrets: HookedSecretStore
  var api: FakeAPI
  var proxy: FakeProxyLauncher
  var temporaryDirectory: URL

  func logs() async -> [StructuredLog] {
    await engine.flushOutbox()
    return await api.logs
  }

  func temporaryEntries() throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
  }

  func opens(with masterKey: String?) -> Bool {
    guard let masterKey else { return false }
    return repository.currentKeys.contains { $0.password == password(masterKey) }
  }
}

private let oldKey = RepositoryKey(id: "key-old", password: password(oldMasterKey))

private func makeKeyFixture(
  keys: [RepositoryKey] = [oldKey],
  secrets: [SecretKey: String] = [.accessToken: "tok", .masterKey: oldMasterKey]
) throws -> KeyFixture {
  let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "key-rotation-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  let repository = FakeKeyRepository(keys: keys)
  let store = HookedSecretStore(secrets)
  let api = FakeAPI()
  let proxy = FakeProxyLauncher()
  let environment = EngineEnvironment(
    secrets: store,
    discover: { _ in ServerInfo(apiRoot: testAPIRoot, resticPackSizeMiB: 16, connectionsMath: "4") },
    makeAPI: { _, _ in api },
    restic: repository,
    proxyLauncher: proxy,
    cacheDirectory: URL(fileURLWithPath: "/tmp/cache"),
    home: "/Users/test",
    processorCount: 8,
    now: { Date(timeIntervalSince1970: 1_700_000_000) },
    temporaryDirectory: temporaryDirectory)
  return KeyFixture(
    engine: BackupEngine(environment: environment), repository: repository, secrets: store, api: api,
    proxy: proxy, temporaryDirectory: temporaryDirectory)
}

private func removeTemporaryDirectory(_ fixture: KeyFixture) {
  try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
}

@Test func changeMasterKeyAddsVerifiesStoresThenRemovesTheOldKey() async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  let displayForm = RepositoryKeys.displayLines(newMasterKey).joined(separator: "\n")

  #expect(try await fixture.engine.changeMasterKey(to: displayForm, config: testConfig()) == .complete)

  #expect(fixture.repository.currentKeys == [RepositoryKey(id: "key-added-1", password: password(newMasterKey))])
  #expect(fixture.secrets.values == [.accessToken: "tok", .masterKey: newMasterKey])
  #expect(fixture.repository.commands == ["key list", "key add", "cat config", "key list", "key remove"])
  #expect(
    fixture.repository.invocations.map { $0.environment["RESTIC_PASSWORD"] }
      == [password(oldMasterKey), password(oldMasterKey)] + Array(repeating: password(newMasterKey), count: 3))
  #expect(fixture.repository.invocations.last?.arguments.last == "key-old")
  let passwordFile = try #require(fixture.repository.passwordFiles.first)
  #expect(fixture.repository.passwordFiles.count == 1)
  #expect(passwordFile.contents == password(newMasterKey))
  #expect(passwordFile.filePermissions == 0o600)
  #expect(passwordFile.directoryPermissions == 0o700)
  #expect(passwordFile.path.hasPrefix(fixture.temporaryDirectory.path + "/futo-backups-key-"))
  #expect(try fixture.temporaryEntries().isEmpty)
  for invocation in fixture.repository.invocations {
    #expect(!invocation.arguments.contains { $0.contains(password(newMasterKey)) || $0.contains(newMasterKey) })
  }
  #expect(fixture.proxy.starts.count == 2)
  #expect(fixture.proxy.stopCount == 2)
  let logs = await fixture.logs()
  #expect(logs.map(\.summary) == ["Changed recovery key"])
  #expect(logs[0].data["repositoryId"] == .string("repo-1"))
  #expect(logs[0].data["oldKeyRemoved"] == .bool(true))
  #expect(logs[0].data["error"] == nil)
  let encoded = String(decoding: try JSONEncoder().encode(logs), as: UTF8.self)
  for secret in [oldMasterKey, newMasterKey, password(oldMasterKey), password(newMasterKey)] {
    #expect(!encoded.contains(secret))
  }
}

private let preconditionCases: [(name: String, input: String, config: AppConfig, secrets: [SecretKey: String])] = [
  ("invalid key", "not a key", testConfig(), [.accessToken: "tok", .masterKey: oldMasterKey]),
  ("no repository", newMasterKey, testConfig(repositoryId: nil), [.accessToken: "tok", .masterKey: oldMasterKey]),
  ("logged out", newMasterKey, testConfig(), [.masterKey: oldMasterKey]),
  ("missing master key", newMasterKey, testConfig(), [.accessToken: "tok"]),
]

@Test(arguments: preconditionCases)
func changeMasterKeyPreconditionsFailBeforeTouchingTheRepository(
  name: String, input: String, config: AppConfig, secrets: [SecretKey: String]
) async throws {
  let fixture = try makeKeyFixture(secrets: secrets)
  defer { removeTemporaryDirectory(fixture) }
  await #expect(throws: (any Error).self, "case: \(name)") {
    _ = try await fixture.engine.changeMasterKey(to: input, config: config)
  }
  #expect(fixture.repository.invocations.isEmpty, "case: \(name)")
  #expect(fixture.proxy.starts.isEmpty, "case: \(name)")
  #expect(fixture.secrets.values == secrets, "case: \(name)")
  #expect(fixture.repository.currentKeys == [oldKey], "case: \(name)")
}

@Test func changeMasterKeyToTheCurrentKeyChangesNothing() async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  #expect(try await fixture.engine.changeMasterKey(to: oldMasterKey, config: testConfig()) == .complete)
  #expect(fixture.repository.invocations.isEmpty)
  #expect(fixture.repository.currentKeys == [oldKey])
}

private let failureBeforeCommitCases:
  [(name: String, arrange: @Sendable (FakeKeyRepository) -> Void, stage: String, error: String)] = [
    ("list fails", { $0.override("key list", with: ResticScript(exitCode: 1)) }, "list", "restic exit 1"),
    (
      "no current key", { $0.override("key list", with: ResticScript(stdout: "[]")) }, "list",
      "currentKeyNotFound"
    ),
    ("add fails", { $0.override("key add", with: ResticScript(exitCode: 1)) }, "add", "restic exit 1"),
    ("new key rejected", { $0.addKeysWithPassword("something else") }, "verify", "newKeyRejected"),
    ("verify fails", { $0.override("cat config", with: ResticScript(exitCode: 1)) }, "verify", "restic exit 1"),
    (
      "verify throws", { $0.override("cat config", with: ResticScript(error: APIError.submit)) },
      "verify", "APIError"
    ),
  ]

@Test(arguments: failureBeforeCommitCases)
func failureBeforeCommitKeepsTheOldKeyInUse(
  name: String, arrange: @Sendable (FakeKeyRepository) -> Void, stage: String, error: String
) async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  arrange(fixture.repository)
  await #expect(throws: (any Error).self, "case: \(name)") {
    _ = try await fixture.engine.changeMasterKey(to: newMasterKey, config: testConfig())
  }
  #expect(fixture.secrets.values == [.accessToken: "tok", .masterKey: oldMasterKey], "case: \(name)")
  #expect(fixture.opens(with: oldMasterKey), "case: \(name)")
  #expect(fixture.repository.currentKeys.contains(oldKey), "case: \(name)")
  #expect(!fixture.repository.commands.contains("key remove"), "case: \(name)")
  #expect(try fixture.temporaryEntries().isEmpty, "case: \(name)")
  #expect(fixture.proxy.stopCount == fixture.proxy.starts.count, "case: \(name)")
  let logs = await fixture.logs()
  #expect(logs.map(\.summary) == ["Changed recovery key"], "case: \(name)")
  #expect(logs.first?.data["stage"] == .string(stage), "case: \(name)")
  #expect(logs.first?.data["error"] == .string(error), "case: \(name)")
}

@Test func masterKeyWriteFailureRollsBackThePendingRecord() async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  fixture.secrets.failWrites(to: .masterKey)
  await #expect(throws: SecretStoreError.keychain(-25293)) {
    _ = try await fixture.engine.changeMasterKey(to: newMasterKey, config: testConfig())
  }
  #expect(fixture.secrets.values == [.accessToken: "tok", .masterKey: oldMasterKey])
  #expect(fixture.opens(with: oldMasterKey))
  #expect(fixture.proxy.stopCount == 2)
  let logs = await fixture.logs()
  #expect(logs.first?.data["stage"] == .string("store"))
  #expect(logs.first?.data["error"] == .string("keychain(-25293)"))
}

@Test func failedRemovalKeepsTheNewKeyAndFinishesLater() async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  fixture.repository.override("key remove", with: ResticScript(exitCode: 1))

  #expect(
    try await fixture.engine.changeMasterKey(to: newMasterKey, config: testConfig()) == .oldKeyRemovalPending)

  #expect(try fixture.secrets.get(.masterKey) == newMasterKey)
  let pendingText = try #require(try fixture.secrets.get(.pendingKeyRotation))
  #expect(
    try JSONDecoder().decode(PendingKeyRotation.self, from: Data(pendingText.utf8))
      == PendingKeyRotation(
        repositoryId: "repo-1", oldKeyId: "key-old", previousMasterKey: oldMasterKey, newMasterKey: newMasterKey))
  #expect(fixture.repository.currentKeys.count == 2)
  var logs = await fixture.logs()
  #expect(logs.last?.data["oldKeyRemoved"] == .bool(false))
  #expect(logs.last?.data["error"] == .string("restic exit 1"))

  fixture.repository.override("key remove", with: nil)
  #expect(try await fixture.engine.finishPendingKeyRotation(config: testConfig()))

  #expect(fixture.repository.currentKeys == [RepositoryKey(id: "key-added-1", password: password(newMasterKey))])
  #expect(fixture.secrets.values == [.accessToken: "tok", .masterKey: newMasterKey])
  #expect(fixture.proxy.stopCount == fixture.proxy.starts.count)
  logs = await fixture.logs()
  #expect(logs.last?.summary == "Finished recovery key change")
  #expect(logs.last?.data["repositoryId"] == .string("repo-1"))
  #expect(logs.last?.data["error"] == nil)
}

enum CrashPoint: String, CaseIterable, Sendable {
  case beforeKeyAdd = "before key add"
  case afterKeyAdd = "after key add"
  case afterVerify = "after cat config"
  case afterPendingStored = "set pending-key-rotation"
  case afterMasterKeyStored = "set master-key"
  case afterOldKeyRemoved = "after key remove"
  case afterPendingCleared = "delete pending-key-rotation"

  var rollsForward: Bool {
    switch self {
    case .beforeKeyAdd, .afterKeyAdd, .afterVerify: false
    case .afterPendingStored, .afterMasterKeyStored, .afterOldKeyRemoved, .afterPendingCleared: true
    }
  }
}

@Test(arguments: CrashPoint.allCases)
func crashAtAnyStepLeavesAWorkingKeyAndResumesToAConsistentState(point: CrashPoint) async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  let capture = CrashCapture()
  let repository = fixture.repository
  let secrets = fixture.secrets
  let record: @Sendable (String) -> Void = { event in
    guard event == point.rawValue else { return }
    capture.capture(CrashCapture.State(secrets: secrets.values, keys: repository.currentKeys))
  }
  repository.setHook(record)
  secrets.setHook(record)
  #expect(try await fixture.engine.changeMasterKey(to: newMasterKey, config: testConfig()) == .complete)
  let crashed = try #require(capture.state)

  let storedAtCrash = try #require(crashed.secrets[.masterKey])
  #expect(crashed.keys.contains { $0.password == password(storedAtCrash) })
  #expect(crashed.secrets[.accessToken] == "tok")

  let relaunched = try makeKeyFixture(keys: crashed.keys, secrets: crashed.secrets)
  defer { removeTemporaryDirectory(relaunched) }
  let finished = try await relaunched.engine.finishPendingKeyRotation(config: testConfig())
  #expect(finished == (crashed.secrets[.pendingKeyRotation] != nil))
  #expect(try relaunched.secrets.get(.pendingKeyRotation) == nil)
  #expect(relaunched.proxy.stopCount == relaunched.proxy.starts.count)

  if point.rollsForward {
    #expect(try relaunched.secrets.get(.masterKey) == newMasterKey)
    #expect(relaunched.repository.currentKeys.map(\.password) == [password(newMasterKey)])
    #expect(!relaunched.opens(with: oldMasterKey))
  } else {
    #expect(try relaunched.secrets.get(.masterKey) == oldMasterKey)
    #expect(relaunched.repository.currentKeys.contains(oldKey))
    #expect(relaunched.repository.invocations.isEmpty)
  }
  #expect(relaunched.opens(with: try relaunched.secrets.get(.masterKey)))
}

@Test func finishWithoutPendingRotationDoesNothing() async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  #expect(try await fixture.engine.finishPendingKeyRotation(config: testConfig()) == false)
  #expect(fixture.repository.invocations.isEmpty)
  #expect(fixture.proxy.starts.isEmpty)
  #expect(await fixture.logs().isEmpty)
}

private func pendingRecord(repositoryId: String = "repo-1") throws -> String {
  String(
    decoding: try JSONEncoder().encode(
      PendingKeyRotation(
        repositoryId: repositoryId, oldKeyId: "key-old", previousMasterKey: oldMasterKey,
        newMasterKey: newMasterKey)),
    as: UTF8.self)
}

@Test func finishRestoresAMissingMasterKeyFromThePendingRecord() async throws {
  let newKey = RepositoryKey(id: "key-new", password: password(newMasterKey))
  let fixture = try makeKeyFixture(
    keys: [oldKey, newKey], secrets: [.accessToken: "tok", .pendingKeyRotation: try pendingRecord()])
  defer { removeTemporaryDirectory(fixture) }
  #expect(try await fixture.engine.finishPendingKeyRotation(config: testConfig()))
  #expect(fixture.secrets.values == [.accessToken: "tok", .masterKey: newMasterKey])
  #expect(fixture.repository.currentKeys == [newKey])
}

@Test(arguments: [("another repository", "repo-2", oldMasterKey), ("superseded key", "repo-1", otherMasterKey)])
func finishDropsAPendingRotationThatNoLongerApplies(name: String, repositoryId: String, stored: String) async throws {
  let newKey = RepositoryKey(id: "key-new", password: password(newMasterKey))
  let fixture = try makeKeyFixture(
    keys: [oldKey, newKey],
    secrets: [.accessToken: "tok", .masterKey: stored, .pendingKeyRotation: try pendingRecord()])
  defer { removeTemporaryDirectory(fixture) }
  #expect(
    try await fixture.engine.finishPendingKeyRotation(config: testConfig(repositoryId: repositoryId)) == false,
    "case: \(name)")
  #expect(fixture.secrets.values == [.accessToken: "tok", .masterKey: stored], "case: \(name)")
  #expect(fixture.repository.invocations.isEmpty, "case: \(name)")
  #expect(fixture.repository.currentKeys == [oldKey, newKey], "case: \(name)")
}

@Test func changeMasterKeyFinishesAnEarlierPendingRotationFirst() async throws {
  let newKey = RepositoryKey(id: "key-new", password: password(newMasterKey))
  let fixture = try makeKeyFixture(
    keys: [oldKey, newKey],
    secrets: [.accessToken: "tok", .masterKey: oldMasterKey, .pendingKeyRotation: try pendingRecord()])
  defer { removeTemporaryDirectory(fixture) }
  #expect(try await fixture.engine.changeMasterKey(to: otherMasterKey, config: testConfig()) == .complete)
  #expect(fixture.secrets.values == [.accessToken: "tok", .masterKey: otherMasterKey])
  #expect(fixture.repository.currentKeys.map(\.password) == [password(otherMasterKey)])
}

@Test func unreadablePendingRecordStopsRotationWithoutChangingKeys() async throws {
  let fixture = try makeKeyFixture(
    secrets: [.accessToken: "tok", .masterKey: oldMasterKey, .pendingKeyRotation: "not json"])
  defer { removeTemporaryDirectory(fixture) }
  await #expect(throws: KeyRotationError.pendingRotationUnreadable) {
    try await fixture.engine.finishPendingKeyRotation(config: testConfig())
  }
  await #expect(throws: KeyRotationError.pendingRotationUnreadable) {
    _ = try await fixture.engine.changeMasterKey(to: newMasterKey, config: testConfig())
  }
  #expect(try fixture.secrets.get(.masterKey) == oldMasterKey)
  #expect(fixture.repository.invocations.isEmpty)
  #expect((await fixture.logs()).last?.data["stage"] == .string("resume"))
}

@Test func stalePasswordDirectoriesAreRemovedBeforeRotating() async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  let stale = fixture.temporaryDirectory.appendingPathComponent("futo-backups-key-stale")
  let unrelated = fixture.temporaryDirectory.appendingPathComponent("unrelated")
  try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
  try Data("left behind".utf8).write(to: stale.appendingPathComponent("password"))
  try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
  _ = try await fixture.engine.changeMasterKey(to: newMasterKey, config: testConfig())
  #expect(try fixture.temporaryEntries() == ["unrelated"])
}

@Test func otherOperationsAreBusyWhileTheKeyChanges() async throws {
  let fixture = try makeKeyFixture()
  defer { removeTemporaryDirectory(fixture) }
  fixture.repository.gate("key add")
  let engine = fixture.engine
  let change = Task { try await engine.changeMasterKey(to: newMasterKey, config: testConfig()) }
  var waited = 0
  while !fixture.repository.commands.contains("key add") {
    waited += 1
    if waited > 500 {
      Issue.record("rotation never reached key add")
      break
    }
    try await Task.sleep(for: .milliseconds(2))
  }
  await #expect(throws: EngineError.busy) {
    _ = try await engine.backup(config: testConfig()) { _ in }
  }
  await #expect(throws: EngineError.busy) {
    _ = try await engine.changeMasterKey(to: otherMasterKey, config: testConfig())
  }
  fixture.repository.release()
  #expect(try await change.value == .complete)
  #expect(try fixture.secrets.get(.masterKey) == newMasterKey)
}
