import Foundation

@testable import BackupsCore

enum APICall: Equatable {
  case list
  case create(name: String)
  case start(repositoryId: String)
  case end(repositoryId: String, status: BackupStatus, durationMs: Int)
  case size(repositoryId: String, sizeBytes: Int64)
}

actor FakeAPI: YuccaRepositoryAPI {
  var calls: [APICall] = []
  var logs: [StructuredLog] = []
  var created = RemoteRepository(id: "new-repo", name: "created", worm: false)
  var submitFailures = false
  var throwIfCancelled = false
  var repositories: [RemoteRepository] = []
  private var logsBlocked = false
  private var logsHanging = false
  private var logWaits: [CheckedContinuation<Void, Never>] = []
  private var masterKeyProbe: (@Sendable () -> Bool)?
  private var onBackupStart: (@Sendable () -> Void)?
  private(set) var sawMasterKeyAtCreate: Bool?

  func setMasterKeyProbe(_ probe: @escaping @Sendable () -> Bool) {
    masterKeyProbe = probe
  }

  func setOnBackupStart(_ hook: @escaping @Sendable () -> Void) {
    onBackupStart = hook
  }

  func listRepositories() async throws -> [RemoteRepository] {
    calls.append(.list)
    return repositories
  }

  func createRepository(name: String) async throws -> RemoteRepository {
    sawMasterKeyAtCreate = masterKeyProbe?()
    calls.append(.create(name: name))
    return created
  }

  func submitBackupStart(repositoryId: String) async throws {
    calls.append(.start(repositoryId: repositoryId))
    onBackupStart?()
    if submitFailures {
      throw APIError.submit
    }
  }

  func submitBackupEnd(repositoryId: String, status: BackupStatus, durationMs: Int) async throws {
    if throwIfCancelled {
      try Task.checkCancellation()
    }
    calls.append(.end(repositoryId: repositoryId, status: status, durationMs: durationMs))
    if submitFailures {
      throw APIError.submit
    }
  }

  func submitStructuredLog(_ log: StructuredLog) async throws {
    if logsBlocked {
      await withCheckedContinuation { (wait: CheckedContinuation<Void, Never>) in
        logWaits.append(wait)
      }
    }
    if logsHanging {
      try await Task.sleep(for: .seconds(3600))
    }
    if throwIfCancelled {
      try Task.checkCancellation()
    }
    logs.append(log)
  }

  func submitRepositorySize(repositoryId: String, sizeBytes: Int64) async throws {
    calls.append(.size(repositoryId: repositoryId, sizeBytes: sizeBytes))
    if submitFailures {
      throw APIError.submit
    }
  }

  func setSubmitFailures(_ value: Bool) {
    submitFailures = value
  }

  func setThrowIfCancelled(_ value: Bool) {
    throwIfCancelled = value
  }

  func blockLogs() {
    logsBlocked = true
  }

  func releaseLogs() {
    logsBlocked = false
    let waits = logWaits
    logWaits = []
    for wait in waits {
      wait.resume()
    }
  }

  func hangStructuredLogs() {
    logsHanging = true
  }

  func setRepositories(_ value: [RemoteRepository]) {
    repositories = value
  }
}

enum APIError: Error { case submit }

struct ResticScript {
  var lines: [String] = []
  var exitCode: Int32 = 0
  var stdout = ""
  var stderr = ""
  var error: (any Error)?
}

final class FakeRestic: ResticExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [ResticInvocation] = []
  private var scripts: [String: ResticScript] = [
    "version": ResticScript(stdout: "{\"version\":\"0.19.1+futo.3\"}")
  ]
  private var gateActive = false
  private var gateChecksCancellation = false
  private var gateWaits: [CheckedContinuation<Void, Never>] = []

  func set(_ script: ResticScript, for command: String) {
    lock.withLock { scripts[command] = script }
  }

  func invocations() -> [ResticInvocation] {
    lock.withLock { recorded }
  }

  func commands() -> [String] {
    invocations().map { $0.arguments.first ?? "" }
  }

  func gateNextBackup(checkingCancellation: Bool = false) {
    lock.withLock {
      gateActive = true
      gateChecksCancellation = checkingCancellation
    }
  }

  func releaseBackups() {
    let waits = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      gateActive = false
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
    let command = invocation.arguments.first ?? ""
    let (script, gated, checksCancellation) = lock.withLock { () -> (ResticScript, Bool, Bool) in
      recorded.append(invocation)
      return (
        scripts[command] ?? ResticScript(), gateActive && command == "backup", gateChecksCancellation
      )
    }
    if gated {
      await withCheckedContinuation { (wait: CheckedContinuation<Void, Never>) in
        lock.withLock { gateWaits.append(wait) }
      }
      if checksCancellation {
        try Task.checkCancellation()
      }
    }
    for line in script.lines {
      onLine(line)
    }
    if let error = script.error {
      throw error
    }
    return ResticResult(exitCode: script.exitCode, stdout: Data(script.stdout.utf8), stderr: script.stderr)
  }
}

struct ProxyStartArg: Equatable {
  var apiRoot: URL
  var throttle: Throttle
}

final class FakeProxyHandle: ResticProxyHandle, @unchecked Sendable {
  let address = "127.0.0.1:4000"
  private let launcher: FakeProxyLauncher

  init(launcher: FakeProxyLauncher) {
    self.launcher = launcher
  }

  func setThrottle(_ throttle: Throttle) throws {}

  func stop() async {
    launcher.recordStop()
  }
}

final class FakeProxyLauncher: ResticProxyLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private var started: [ProxyStartArg] = []
  private var stops = 0
  private var failure: (any Error)?
  private var onStartHook: (@Sendable () -> Void)?

  func setStartFailure(_ error: any Error) {
    lock.withLock { failure = error }
  }

  func setOnStart(_ hook: @escaping @Sendable () -> Void) {
    lock.withLock { onStartHook = hook }
  }

  var starts: [ProxyStartArg] {
    lock.withLock { started }
  }

  var stopCount: Int {
    lock.withLock { stops }
  }

  func recordStop() {
    lock.withLock { stops += 1 }
  }

  func start(apiRoot: URL, throttle: Throttle) async throws -> any ResticProxyHandle {
    let result = lock.withLock { () -> (failure: (any Error)?, hook: (@Sendable () -> Void)?) in
      started.append(ProxyStartArg(apiRoot: apiRoot, throttle: throttle))
      return (failure, onStartHook)
    }
    if let failure = result.failure {
      throw failure
    }
    result.hook?()
    return FakeProxyHandle(launcher: self)
  }
}

final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var stored = 0

  func increment() {
    lock.withLock { stored += 1 }
  }

  var value: Int {
    lock.withLock { stored }
  }
}

final class FixedClock: @unchecked Sendable {
  private let lock = NSLock()
  private var ticks = 0

  func now() -> Date {
    lock.withLock {
      let date = Date(timeIntervalSince1970: 1_700_000_000) + Double(ticks)
      ticks += 1
      return date
    }
  }
}

final class ActivityLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [EngineActivity] = []

  func record(_ activity: EngineActivity) {
    lock.withLock { stored.append(activity) }
  }

  var all: [EngineActivity] {
    lock.withLock { stored }
  }
}

let testMasterKey = String(repeating: "00112233445566778899aabbccddeeff", count: 2)
let testServerURL = URL(string: "http://server.test/yucca.json")!
let testAPIRoot = URL(string: "http://server.test/api")!

struct EngineFixture {
  var environment: EngineEnvironment
  var api: FakeAPI
  var restic: FakeRestic
  var proxy: FakeProxyLauncher
  var secrets: InMemorySecretStore
  var discoverCount: Counter
}

extension EngineFixture {
  func deliveredCalls(_ engine: BackupEngine) async -> [APICall] {
    await engine.flushOutbox()
    return await api.calls
  }

  func deliveredLogs(_ engine: BackupEngine) async -> [StructuredLog] {
    await engine.flushOutbox()
    return await api.logs
  }
}

func makeFixture(
  connectionsMath: String = "16", token: String? = "tok", masterKey: String? = testMasterKey,
  appVersion: String = "dev", telemetryTimeout: Duration = .seconds(10)
) -> EngineFixture {
  let api = FakeAPI()
  let restic = FakeRestic()
  let proxy = FakeProxyLauncher()
  var secretValues: [SecretKey: String] = [:]
  if let token {
    secretValues[.accessToken] = token
  }
  if let masterKey {
    secretValues[.masterKey] = masterKey
  }
  let secrets = InMemorySecretStore(secretValues)
  let discoverCount = Counter()
  let clock = FixedClock()
  let environment = EngineEnvironment(
    secrets: secrets,
    discover: { _ in
      discoverCount.increment()
      return ServerInfo(
        apiRoot: testAPIRoot, resticPackSizeMiB: 16, connectionsMath: connectionsMath)
    },
    makeAPI: { _, _ in api },
    restic: restic,
    proxyLauncher: proxy,
    cacheDirectory: URL(fileURLWithPath: "/tmp/cache"),
    home: "/Users/test",
    processorCount: 8,
    now: { clock.now() },
    appVersion: appVersion,
    telemetryTimeout: telemetryTimeout)
  return EngineFixture(
    environment: environment, api: api, restic: restic, proxy: proxy, secrets: secrets,
    discoverCount: discoverCount)
}

func testConfig(
  repositoryId: String? = "repo-1", folders: [String] = ["/data"], consented: Bool = true
) -> AppConfig {
  var config = AppConfig.defaults(host: "test-host", home: "/Users/test")
  config.serverURL = testServerURL
  config.folders = folders
  config.excludes = []
  config.repositoryId = repositoryId
  if consented {
    config.telemetryConsentedAt = Date(timeIntervalSince1970: 1_690_000_000)
  }
  return config
}

func argumentAfter(_ arguments: [String], _ flag: String) -> String? {
  guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
    return nil
  }
  return arguments[index + 1]
}
