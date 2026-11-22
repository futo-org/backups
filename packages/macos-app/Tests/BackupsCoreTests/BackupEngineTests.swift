import Foundation
import Testing

@testable import BackupsCore

private let statusLineOne =
  #"{"message_type":"status","percent_done":50,"total_files":10,"files_done":5,"total_bytes":100,"bytes_done":50}"#
private let statusLineTwo =
  #"{"message_type":"status","percent_done":100,"total_files":10,"files_done":10,"total_bytes":100,"bytes_done":100}"#
private let summaryLine =
  #"{"message_type":"summary","files_new":7,"files_changed":1,"files_unmodified":2,"data_added":999,"total_files_processed":10,"total_bytes_processed":1000,"snapshot_id":"snapshot-abc"}"#
private let errorLine = #"{"message_type":"error","error":{"message":"permission denied"},"item":"/a/b"}"#
private let statsStdout = #"{"total_size":4321}"#
private let backupLines = [statusLineOne, statusLineTwo, summaryLine]

@Test func masterKeyExistingReturnedAndGeneratedStored() async throws {
  let seeded = makeFixture()
  let seededEngine = BackupEngine(environment: seeded.environment)
  #expect(try await seededEngine.masterKey() == testMasterKey)

  let fresh = makeFixture(masterKey: nil)
  let freshEngine = BackupEngine(environment: fresh.environment)
  let generated = try await freshEngine.masterKey()
  #expect(RepositoryKeys.isValidMasterKey(generated))
  #expect(try fresh.secrets.get(.masterKey) == generated)
  #expect(try await freshEngine.masterKey() == generated)
}

@Test func importMasterKeyStoresNormalizedKeyAndRejectsInvalid() async throws {
  let fixture = makeFixture(masterKey: nil)
  let engine = BackupEngine(environment: fixture.environment)
  let spaced = RepositoryKeys.displayLines(testMasterKey).joined(separator: "\n")
  try await engine.importMasterKey(spaced)
  #expect(try fixture.secrets.get(.masterKey) == testMasterKey.lowercased())
  #expect(try await engine.masterKey() == testMasterKey.lowercased())
  await #expect(throws: RepositoryKeysError.invalidMasterKey) {
    try await engine.importMasterKey("not a key")
  }
  #expect(try fixture.secrets.get(.masterKey) == testMasterKey.lowercased())
}

@Test func ensureRepositoryReturnsExistingIdWithoutCalls() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  #expect(try await engine.ensureRepository(config: testConfig()) == "repo-1")
  #expect(await fixture.deliveredCalls(engine).isEmpty)
  #expect(fixture.restic.commands().isEmpty)
  #expect(fixture.proxy.starts.isEmpty)
  #expect(fixture.discoverCount.value == 0)
}

@Test func ensureRepositoryCreatesInitialisesAndStopsProxy() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  let config = testConfig(repositoryId: nil)
  #expect(try await engine.ensureRepository(config: config) == "new-repo")
  #expect(await fixture.deliveredCalls(engine) == [.create(name: "test-host")])
  #expect(fixture.restic.commands() == ["version", "init"])
  let startArgs = fixture.proxy.starts
  #expect(startArgs == [ProxyStartArg(apiRoot: testAPIRoot, throttle: config.throttle)])
  #expect(fixture.proxy.stopCount == 1)
  let initInvocation = try #require(fixture.restic.invocations().first { $0.arguments.first == "init" })
  #expect(initInvocation.environment["RESTIC_REPOSITORY"] == "rest:http://new-repo:tok@127.0.0.1:4000")
  let expectedPassword = try RepositoryKeys.password(masterKey: testMasterKey, repositoryId: "new-repo")
  #expect(initInvocation.environment["RESTIC_PASSWORD"] == expectedPassword)
}

@Test func ensureRepositoryInitFailureThrowsAndStopsProxy() async throws {
  let fixture = makeFixture()
  fixture.restic.set(
    ResticScript(
      exitCode: 1,
      stderr: #"{"message_type":"exit_error","code":1,"message":"boom"}"#),
    for: "init")
  let engine = BackupEngine(environment: fixture.environment)
  await #expect(throws: EngineError.restic(code: 1, message: "boom")) {
    _ = try await engine.ensureRepository(config: testConfig(repositoryId: nil))
  }
  #expect(fixture.proxy.stopCount == 1)
}

@Test func backupPreconditionsThrowWithoutCalls() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  await #expect(throws: EngineError.noRepository) {
    _ = try await engine.backup(config: testConfig(repositoryId: nil), onActivity: { _ in })
  }
  await #expect(throws: EngineError.noFolders) {
    _ = try await engine.backup(config: testConfig(folders: []), onActivity: { _ in })
  }
  let loggedOut = makeFixture(token: nil)
  let loggedOutEngine = BackupEngine(environment: loggedOut.environment)
  await #expect(throws: EngineError.notLoggedIn) {
    _ = try await loggedOutEngine.backup(config: testConfig(), onActivity: { _ in })
  }
  #expect(await fixture.deliveredCalls(engine).isEmpty)
  #expect(fixture.restic.commands().isEmpty)
  #expect(fixture.proxy.starts.isEmpty)
  #expect(fixture.discoverCount.value == 0)
  #expect(loggedOut.restic.commands().isEmpty)
  #expect(loggedOut.discoverCount.value == 0)
}

@Test func backupSuccessSequenceAndReporting() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: backupLines), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  let engine = BackupEngine(environment: fixture.environment)
  let log = ActivityLog()
  let record = try await engine.backup(config: testConfig()) { log.record($0) }
  #expect(record.status == .complete)
  #expect(record.snapshotId == "snapshot-abc")
  #expect(record.filesNew == 7)
  #expect(record.dataAdded == 999)
  #expect(record.message == nil)
  #expect(record.finishedAt > record.startedAt)
  #expect(fixture.restic.commands() == ["version", "unlock", "backup", "forget", "stats"])
  let backupInvocation = try #require(
    fixture.restic.invocations().first { $0.arguments.first == "backup" })
  let backupArgs = backupInvocation.arguments
  #expect(argumentAfter(backupArgs, "--walk-concurrency") == "64")
  #expect(argumentAfter(backupArgs, "--option") == "rest.connections=16")
  #expect(argumentAfter(backupArgs, "--host") == "test-host")
  let forgetInvocation = try #require(
    fixture.restic.invocations().first { $0.arguments.first == "forget" })
  #expect(argumentAfter(forgetInvocation.arguments, "--keep-within") == BackupEngine.keepWithin)
  #expect(argumentAfter(forgetInvocation.arguments, "--host") == "test-host")
  #expect(
    log.all
      == [
        .preparing,
        .backingUp(BackupProgress(percentDone: 50, totalFiles: 10, filesDone: 5, totalBytes: 100, bytesDone: 50)),
        .backingUp(
          BackupProgress(percentDone: 100, totalFiles: 10, filesDone: 10, totalBytes: 100, bytesDone: 100)),
        .pruning,
      ])
  var calls = await fixture.deliveredCalls(engine)
  #expect(calls.count == 3)
  #expect(calls[0] == .start(repositoryId: "repo-1"))
  #expect(calls[1] == .size(repositoryId: "repo-1", sizeBytes: 4321))
  if case .end(let id, let status, let durationMs)? = calls.last {
    #expect(id == "repo-1")
    #expect(status == .complete)
    #expect(durationMs > 0)
  } else {
    Issue.record("missing backup end call")
  }
  #expect(fixture.proxy.stopCount == 1)
  #expect(fixture.discoverCount.value == 1)
  let second = try await engine.backup(config: testConfig()) { _ in }
  #expect(second.status == .complete)
  #expect(fixture.restic.commands().filter { $0 == "version" }.count == 1)
  #expect(fixture.discoverCount.value == 1)
  calls = await fixture.deliveredCalls(engine)
  #expect(calls.count == 6)
}

@Test func backupUsesProcessorCountAndNoWalkConcurrencyForPlainRestic() async throws {
  let fixture = makeFixture(connectionsMath: "min(cores, 8)")
  fixture.restic.set(ResticScript(stdout: "{\"version\":\"0.17.0\"}"), for: "version")
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  let backupArgs = try #require(
    fixture.restic.invocations().first { $0.arguments.first == "backup" }
  ).arguments
  #expect(argumentAfter(backupArgs, "--option") == "rest.connections=8")
  #expect(!backupArgs.contains("--walk-concurrency"))
}

@Test func backupExitThreeWarnsAndSkipsForget() async throws {
  let fixture = makeFixture()
  fixture.restic.set(
    ResticScript(
      lines: [errorLine], exitCode: 3,
      stderr: #"{"message_type":"exit_error","code":3,"message":"read failed"}"#),
    for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  let engine = BackupEngine(environment: fixture.environment)
  let log = ActivityLog()
  let record = try await engine.backup(config: testConfig()) { log.record($0) }
  #expect(record.status == .warn)
  #expect(record.message == "/a/b: permission denied")
  #expect(fixture.restic.commands() == ["version", "unlock", "backup", "stats"])
  #expect(log.all == [.preparing])
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .size(repositoryId: "repo-1", sizeBytes: 4321),
        .end(repositoryId: "repo-1", status: .warn, durationMs: 1000),
      ])
  #expect(fixture.proxy.stopCount == 1)
}

@Test func backupExitOneFailsWithoutForgetOrStats() async throws {
  let fixture = makeFixture()
  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"no space"}"#),
    for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == "no space")
  #expect(record.snapshotId == nil)
  #expect(fixture.restic.commands() == ["version", "unlock", "backup"])
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .end(repositoryId: "repo-1", status: .failed, durationMs: 1000),
      ])
}

@Test func backupForgetFailureKeepsCompleteWithPruneMessage() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"prune boom"}"#),
    for: "forget")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  #expect(record.message == "Prune failed: prune boom")
  #expect(fixture.restic.commands() == ["version", "unlock", "backup", "forget", "stats"])
  #expect(
    await fixture.deliveredCalls(engine).last == .end(repositoryId: "repo-1", status: .complete, durationMs: 1000))
}

@Test func backupForgetThrowKeepsCompleteWithPruneMessage() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  fixture.restic.set(ResticScript(error: CocoaError(.fileNoSuchFile)), for: "forget")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  let message = try #require(record.message)
  #expect(message.hasPrefix("Prune failed: "))
  #expect(fixture.restic.commands() == ["version", "unlock", "backup", "forget", "stats"])
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .size(repositoryId: "repo-1", sizeBytes: 4321),
        .end(repositoryId: "repo-1", status: .complete, durationMs: 1000),
      ])
  #expect(fixture.proxy.stopCount == 1)
}

@Test func backupForgetThrowCancellationProducesCancelledRecord() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(error: CancellationError()), for: "forget")
  let engine = BackupEngine(environment: fixture.environment)
  let log = ActivityLog()
  let record = try await engine.backup(config: testConfig()) { log.record($0) }
  #expect(record.status == .cancelled)
  #expect(record.message == nil)
  #expect(log.all == [.preparing, .pruning])
  #expect(fixture.restic.commands() == ["version", "unlock", "backup", "forget"])
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .end(repositoryId: "repo-1", status: .cancelled, durationMs: 1000),
      ])
  #expect(fixture.proxy.stopCount == 1)
}

@Test func backupCancellationProducesCancelledRecord() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(error: CancellationError()), for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let log = ActivityLog()
  let record = try await engine.backup(config: testConfig()) { log.record($0) }
  #expect(record.status == .cancelled)
  #expect(record.message == nil)
  #expect(log.all == [.preparing])
  #expect(fixture.restic.commands() == ["version", "unlock", "backup"])
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .end(repositoryId: "repo-1", status: .cancelled, durationMs: 1000),
      ])
  #expect(fixture.proxy.stopCount == 1)
}

@Test func backupSucceedsWhenSubmissionsThrow() async throws {
  let fixture = makeFixture()
  await fixture.api.setSubmitFailures(true)
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  #expect(record.snapshotId == "snapshot-abc")
}

@Test func backupProxyStartFailureProducesFailedRecord() async throws {
  let fixture = makeFixture()
  fixture.proxy.setStartFailure(ResticProxyError.notReady("proxy down"))
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == String(describing: ResticProxyError.notReady("proxy down")))
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .end(repositoryId: "repo-1", status: .failed, durationMs: 1000),
      ])
  #expect(fixture.restic.commands().isEmpty)
  #expect(fixture.proxy.stopCount == 0)
}

@Test func busyBlocksSecondBackupAndRestoreUntilRelease() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  fixture.restic.gateNextBackup()
  let engine = BackupEngine(environment: fixture.environment)
  let task = Task {
    try await engine.backup(config: testConfig()) { _ in }
  }
  var waited = 0
  while !fixture.restic.commands().contains("backup") {
    waited += 1
    if waited > 500 {
      Issue.record("backup never reached restic fake")
      break
    }
    try await Task.sleep(for: .milliseconds(2))
  }
  await #expect(throws: EngineError.busy) {
    _ = try await engine.backup(config: testConfig()) { _ in }
  }
  await #expect(throws: EngineError.busy) {
    try await engine.restore(
      config: testConfig(), snapshotId: "snap-1", target: URL(fileURLWithPath: "/tmp/out"), include: []
    ) { _ in }
  }
  fixture.restic.releaseBackups()
  let first = try await task.value
  #expect(first.status == .complete)
  let third = try await engine.backup(config: testConfig()) { _ in }
  #expect(third.status == .complete)
  #expect(fixture.restic.commands().filter { $0 == "version" }.count == 1)
  #expect(fixture.proxy.stopCount == 2)
}

@Test func snapshotsSortedNewestFirstAndWrongPasswordThrows() async throws {
  let fixture = makeFixture()
  fixture.restic.set(
    ResticScript(
      stdout: """
        [
          {"id":"old","short_id":"old","time":"2025-01-01T00:00:00Z","paths":["/data"],"hostname":"test-host"},
          {"id":"newest","short_id":"newest","time":"2025-06-01T00:00:00Z","paths":["/data"],"hostname":"test-host"},
          {"id":"mid","short_id":"mid","time":"2025-03-01T00:00:00Z","paths":["/data"],"hostname":"test-host"}
        ]
        """),
    for: "snapshots")
  let engine = BackupEngine(environment: fixture.environment)
  let snapshots = try await engine.snapshots(config: testConfig())
  #expect(snapshots.map(\.id) == ["newest", "mid", "old"])

  let broken = makeFixture()
  broken.restic.set(
    ResticScript(
      exitCode: 12, stderr: #"{"message_type":"exit_error","code":12,"message":"wrong password"}"#),
    for: "snapshots")
  let brokenEngine = BackupEngine(environment: broken.environment)
  await #expect(throws: EngineError.restic(code: 12, message: "wrong password")) {
    _ = try await brokenEngine.snapshots(config: testConfig())
  }
}

@Test func restoreRunsExpectedCommandAndMapsFailure() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  let log = ActivityLog()
  try await engine.restore(
    config: testConfig(), snapshotId: "snap-1", target: URL(fileURLWithPath: "/tmp/out"), include: ["/a", "/b"]
  ) { log.record($0) }
  #expect(log.all == [.restoring])
  let restoreInvocation = try #require(
    fixture.restic.invocations().first { $0.arguments.first == "restore" })
  #expect(
    Array(restoreInvocation.arguments.suffix(7))
      == ["--target", "/tmp/out", "--include", "/a", "--include", "/b", "snap-1"])
  #expect(fixture.proxy.stopCount == 1)

  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"restore failed"}"#),
    for: "restore")
  await #expect(throws: EngineError.restic(code: 1, message: "restore failed")) {
    try await engine.restore(
      config: testConfig(), snapshotId: "snap-1", target: URL(fileURLWithPath: "/tmp/out"), include: []
    ) { _ in }
  }
  #expect(fixture.proxy.stopCount == 2)
}

@Test func storedMasterKeyReturnsStoredValueAndNeverGenerates() async throws {
  let fresh = makeFixture(masterKey: nil)
  let freshEngine = BackupEngine(environment: fresh.environment)
  #expect(try await freshEngine.storedMasterKey() == nil)
  #expect(try fresh.secrets.get(.masterKey) == nil)
  let seeded = makeFixture()
  let seededEngine = BackupEngine(environment: seeded.environment)
  #expect(try await seededEngine.storedMasterKey() == testMasterKey)
}

private let missingKeyOperations: [(name: String, run: @Sendable (BackupEngine) async throws -> Void)] = [
  ("backup", { engine in _ = try await engine.backup(config: testConfig(), onActivity: { _ in }) }),
  ("snapshots", { engine in _ = try await engine.snapshots(config: testConfig()) }),
  (
    "restore",
    { engine in
      try await engine.restore(
        config: testConfig(), snapshotId: "snap-1", target: URL(fileURLWithPath: "/tmp/out"), include: []
      ) { _ in }
    }
  ),
]

@Test(arguments: missingKeyOperations)
func missingMasterKeyThrowsAndIsNeverGenerated(
  name: String, run: @Sendable (BackupEngine) async throws -> Void
) async throws {
  let fixture = makeFixture(masterKey: nil)
  let engine = BackupEngine(environment: fixture.environment)
  await #expect(throws: EngineError.missingMasterKey, "operation: \(name)") {
    try await run(engine)
  }
  #expect(try fixture.secrets.get(.masterKey) == nil)
  #expect(fixture.restic.commands().isEmpty)
  #expect(fixture.proxy.starts.isEmpty)
}

@Test func ensureRepositoryWithoutStoredKeyThrowsAndNeverCreates() async throws {
  let fixture = makeFixture(masterKey: nil)
  let engine = BackupEngine(environment: fixture.environment)
  await #expect(throws: EngineError.missingMasterKey) {
    _ = try await engine.ensureRepository(config: testConfig(repositoryId: nil))
  }
  #expect(await fixture.deliveredCalls(engine).isEmpty)
  #expect(try fixture.secrets.get(.masterKey) == nil)
  #expect(fixture.restic.commands().isEmpty)
  #expect(fixture.proxy.starts.isEmpty)
}

@Test func ensureRepositoryHasStoredKeyWhenCreateRepositoryIsCalled() async throws {
  let fixture = makeFixture()
  let secrets = fixture.secrets
  await fixture.api.setMasterKeyProbe {
    (try? secrets.get(.masterKey)) != nil
  }
  let engine = BackupEngine(environment: fixture.environment)
  #expect(try await engine.ensureRepository(config: testConfig(repositoryId: nil)) == "new-repo")
  #expect(await fixture.api.sawMasterKeyAtCreate == true)
  let initInvocation = try #require(fixture.restic.invocations().first { $0.arguments.first == "init" })
  let expectedPassword = try RepositoryKeys.password(masterKey: testMasterKey, repositoryId: "new-repo")
  #expect(initInvocation.environment["RESTIC_PASSWORD"] == expectedPassword)
  #expect(fixture.proxy.stopCount == 1)
}

@Test func macRepositoriesFiltersAndSortsByLastBackupThenName() async throws {
  let tieZulu = RemoteRepository(
    id: "tie-zulu", name: "zulu", worm: false, lastBackup: "2026-11-21T00:00:00Z", connectionType: "macos")
  let tieAlpha = RemoteRepository(
    id: "tie-alpha", name: "alpha", worm: false, lastBackup: "2026-11-21T00:00:00Z", connectionType: "macos")
  let older = RemoteRepository(
    id: "older", name: "older-mac", worm: false, lastBackup: "2026-11-20T23:59:59Z", connectionType: "macos")
  let never = RemoteRepository(id: "never", name: "never-backed-up", worm: false, connectionType: "macos")
  let windows = RemoteRepository(
    id: "windows", name: "win", worm: false, lastBackup: "2026-11-22T00:00:00Z", connectionType: "windows")
  let web = RemoteRepository(id: "web", name: "web", worm: false, lastBackup: "2026-11-23T00:00:00Z")
  let fixture = makeFixture()
  await fixture.api.setRepositories([older, windows, never, web, tieZulu, tieAlpha])
  let engine = BackupEngine(environment: fixture.environment)
  let listed = try await engine.macRepositories(config: testConfig())
  #expect(listed.map(\.id) == ["tie-alpha", "tie-zulu", "older", "never"])
  #expect(await fixture.deliveredCalls(engine) == [.list])
  #expect(fixture.discoverCount.value == 1)
  let loggedOut = makeFixture(token: nil)
  await loggedOut.api.setRepositories([tieAlpha])
  let loggedOutEngine = BackupEngine(environment: loggedOut.environment)
  await #expect(throws: EngineError.notLoggedIn) {
    _ = try await loggedOutEngine.macRepositories(config: testConfig())
  }
  #expect(await loggedOut.deliveredCalls(loggedOutEngine).isEmpty)
}

@Test func verifyMasterKeyUsesGivenKeyAndMapsExitCode() async throws {
  let storedKey = String(repeating: "ffeeddccbbaa99887766554433221100", count: 2)
  let expectedPassword = try RepositoryKeys.password(masterKey: testMasterKey, repositoryId: "repo-1")
  let storedPassword = try RepositoryKeys.password(masterKey: storedKey, repositoryId: "repo-1")
  #expect(expectedPassword != storedPassword)

  let ok = makeFixture(masterKey: storedKey)
  let okEngine = BackupEngine(environment: ok.environment)
  #expect(try await okEngine.verifyMasterKey(testMasterKey, config: testConfig(), repositoryId: "repo-1"))
  let displayForm = RepositoryKeys.displayLines(testMasterKey).joined(separator: "\n")
  #expect(try await okEngine.verifyMasterKey(displayForm, config: testConfig(), repositoryId: "repo-1"))
  let catInvocations = ok.restic.invocations().filter { $0.arguments.first == "cat" }
  #expect(catInvocations.count == 2)
  for invocation in catInvocations {
    #expect(invocation.environment["RESTIC_PASSWORD"] == expectedPassword)
  }
  #expect(Array(catInvocations[0].arguments.prefix(2)) == ["cat", "config"])
  #expect(ok.proxy.stopCount == 2)
  #expect(try ok.secrets.get(.masterKey) == storedKey)

  let wrong = makeFixture(masterKey: storedKey)
  wrong.restic.set(ResticScript(exitCode: ResticExitCode.wrongPassword), for: "cat")
  let wrongEngine = BackupEngine(environment: wrong.environment)
  #expect(
    try await wrongEngine.verifyMasterKey(testMasterKey, config: testConfig(), repositoryId: "repo-1") == false)
  #expect(wrong.proxy.stopCount == 1)
  #expect(try wrong.secrets.get(.masterKey) == storedKey)

  let failed = makeFixture(masterKey: storedKey)
  failed.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"network gone"}"#),
    for: "cat")
  let failedEngine = BackupEngine(environment: failed.environment)
  await #expect(throws: EngineError.restic(code: 1, message: "network gone")) {
    _ = try await failedEngine.verifyMasterKey(testMasterKey, config: testConfig(), repositoryId: "repo-1")
  }
  #expect(failed.proxy.stopCount == 1)
  #expect(try failed.secrets.get(.masterKey) == storedKey)

  let thrown = makeFixture(masterKey: storedKey)
  thrown.restic.set(ResticScript(error: CocoaError(.fileNoSuchFile)), for: "cat")
  let thrownEngine = BackupEngine(environment: thrown.environment)
  await #expect(throws: CocoaError.self) {
    _ = try await thrownEngine.verifyMasterKey(testMasterKey, config: testConfig(), repositoryId: "repo-1")
  }
  #expect(thrown.proxy.stopCount == 1)
  #expect(try thrown.secrets.get(.masterKey) == storedKey)
}

@Test func verifyMasterKeyRejectsInvalidKeyBeforeProxyStarts() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  await #expect(throws: RepositoryKeysError.invalidMasterKey) {
    _ = try await engine.verifyMasterKey("0011 2233 nope", config: testConfig(), repositoryId: "repo-1")
  }
  #expect(fixture.proxy.starts.isEmpty)
  #expect(fixture.restic.commands().isEmpty)
  #expect(try fixture.secrets.get(.masterKey) == testMasterKey)
}

@Test func verifyMasterKeyThrowsBusyWhileBackupRuns() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  fixture.restic.gateNextBackup()
  let engine = BackupEngine(environment: fixture.environment)
  let task = Task {
    try await engine.backup(config: testConfig()) { _ in }
  }
  var waited = 0
  while !fixture.restic.commands().contains("backup") {
    waited += 1
    if waited > 500 {
      Issue.record("backup never reached restic fake")
      break
    }
    try await Task.sleep(for: .milliseconds(2))
  }
  await #expect(throws: EngineError.busy) {
    _ = try await engine.verifyMasterKey(testMasterKey, config: testConfig(), repositoryId: "repo-1")
  }
  fixture.restic.releaseBackups()
  let record = try await task.value
  #expect(record.status == .complete)
  #expect(try fixture.secrets.get(.masterKey) == testMasterKey)
}

@Test func snapshotsUsesTokenReadBeforeProxyStart() async throws {
  let fixture = makeFixture(token: "tok-original")
  fixture.restic.set(ResticScript(stdout: "[]"), for: "snapshots")
  let secrets = fixture.secrets
  fixture.proxy.setOnStart {
    _ = try? secrets.set("tok-swapped", for: .accessToken)
  }
  let engine = BackupEngine(environment: fixture.environment)
  #expect(try await engine.snapshots(config: testConfig()).isEmpty)
  let invocation = try #require(
    fixture.restic.invocations().first { $0.arguments.first == "snapshots" })
  let repository = try #require(invocation.environment["RESTIC_REPOSITORY"])
  #expect(repository.contains("tok-original"))
  #expect(!repository.contains("tok-swapped"))
}

@Test func verifyMasterKeyUsesTokenReadBeforeProxyStart() async throws {
  let fixture = makeFixture(token: "tok-original")
  let secrets = fixture.secrets
  fixture.proxy.setOnStart {
    _ = try? secrets.set("tok-swapped", for: .accessToken)
  }
  let engine = BackupEngine(environment: fixture.environment)
  #expect(
    try await engine.verifyMasterKey(
      testMasterKey, config: testConfig(), repositoryId: "repo-1"))
  let invocation = try #require(fixture.restic.invocations().first { $0.arguments.first == "cat" })
  let repository = try #require(invocation.environment["RESTIC_REPOSITORY"])
  #expect(repository.contains("tok-original"))
  #expect(!repository.contains("tok-swapped"))
}

@Test func backupUsesTokenReadBeforeSubmitBackupStart() async throws {
  let fixture = makeFixture(token: "tok-original")
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  let secrets = fixture.secrets
  await fixture.api.setOnBackupStart {
    _ = try? secrets.set("tok-swapped", for: .accessToken)
  }
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  await engine.flushOutbox()
  #expect(try fixture.secrets.get(.accessToken) == "tok-swapped")
  let invocation = try #require(
    fixture.restic.invocations().first { $0.arguments.first == "backup" })
  let repository = try #require(invocation.environment["RESTIC_REPOSITORY"])
  #expect(repository.contains("tok-original"))
  #expect(!repository.contains("tok-swapped"))
}

@Test func backupSuccessEmitsTelemetryEventsInOrder() async throws {
  let fixture = makeFixture(appVersion: "9.9.9")
  fixture.restic.set(ResticScript(lines: backupLines), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  let logs = await fixture.deliveredLogs(engine)
  #expect(
    logs.map(\.summary)
      == [
        "Running backup",
        "Running repository prune",
        "Finished repository prune",
        "Backup finished",
      ])
  for log in logs {
    #expect(log.data["version"] == .string("9.9.9"), "summary: \(log.summary)")
    #expect(log.data["client"] == .string("macos"), "summary: \(log.summary)")
  }
  #expect(logs[0].data["repositoryId"] == .string("repo-1"))
  #expect(logs[1].data["repositoryId"] == .string("repo-1"))
  #expect(logs[1].data["retentionPolicy"] == .string("keep-within 60d"))
  #expect(logs[2].data["repositoryId"] == .string("repo-1"))
  #expect(logs[2].data["error"] == nil)
  let finished = logs[3]
  #expect(finished.data["repositoryId"] == .string("repo-1"))
  #expect(finished.data["lastBackupStatus"] == .string("complete"))
  #expect(finished.data["durationMs"] == .int(1000))
  #expect(finished.data["error"] == nil)
}

@Test func failedBackupEmitsFinishedEventWithFailure() async throws {
  let fixture = makeFixture()
  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"no space"}"#),
    for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .failed)
  let logs = await fixture.deliveredLogs(engine)
  #expect(logs.map(\.summary) == ["Running backup", "Backup finished"])
  let finished = try #require(logs.last)
  #expect(finished.data["lastBackupStatus"] == .string("failed"))
  #expect(finished.data["durationMs"] == .int(1000))
  #expect(finished.data["error"] == .string("no space"))
}

@Test func pruneFailureEmitsFinishedPruneWithErrorWithoutFinishedError() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"prune boom"}"#),
    for: "forget")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  #expect(record.message == "Prune failed: prune boom")
  let logs = await fixture.deliveredLogs(engine)
  let finishedPrune = try #require(logs.first { $0.summary == "Finished repository prune" })
  #expect(finishedPrune.data["repositoryId"] == .string("repo-1"))
  #expect(finishedPrune.data["error"] == .string("prune boom"))
  let finished = try #require(logs.last)
  #expect(finished.summary == "Backup finished")
  #expect(finished.data["lastBackupStatus"] == .string("complete"))
  #expect(finished.data["error"] == nil)
}

@Test func statsNonZeroExitEmitsStatsFailureEventAndSkipsSize() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"stats gone"}"#),
    for: "stats")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  let logs = await fixture.deliveredLogs(engine)
  let stats = try #require(logs.first { $0.summary == "Failed to read repository stats" })
  #expect(stats.data["repositoryId"] == .string("repo-1"))
  #expect(stats.data["error"] == .string("stats gone"))
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .end(repositoryId: "repo-1", status: .complete, durationMs: 1000),
      ])
}

@Test func withoutConsentNoLogsAreSentAndMetricsCallsUnchanged() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig(consented: false)) { _ in }
  #expect(record.status == .complete)
  #expect(await fixture.deliveredLogs(engine).isEmpty)
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .size(repositoryId: "repo-1", sizeBytes: 4321),
        .end(repositoryId: "repo-1", status: .complete, durationMs: 1000),
      ])
}

@Test func genuinelyCancelledBackupWithThrowingTransportDeliversCancelledEndAndFinished() async throws {
  let fixture = makeFixture()
  await fixture.api.setThrowIfCancelled(true)
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.gateNextBackup(checkingCancellation: true)
  let engine = BackupEngine(environment: fixture.environment)
  let task = Task {
    try await engine.backup(config: testConfig()) { _ in }
  }
  var waited = 0
  while !fixture.restic.commands().contains("backup") {
    waited += 1
    if waited > 500 {
      Issue.record("backup never reached restic fake")
      break
    }
    try await Task.sleep(for: .milliseconds(2))
  }
  task.cancel()
  fixture.restic.releaseBackups()
  let record = try await task.value
  #expect(record.status == .cancelled)
  #expect(record.message == nil)
  let calls = await fixture.deliveredCalls(engine)
  #expect(calls.contains(.end(repositoryId: "repo-1", status: .cancelled, durationMs: 1000)))
  let logs = await fixture.deliveredLogs(engine)
  #expect(logs.map(\.summary) == ["Running backup", "Backup finished"])
  let finished = try #require(logs.last)
  #expect(finished.data["lastBackupStatus"] == .string("cancelled"))
  #expect(finished.data["error"] == nil)
}

@Test func deliversEndAndLogsWhenTaskCancelledDuringResticRun() async throws {
  let fixture = makeFixture()
  await fixture.api.setThrowIfCancelled(true)
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  fixture.restic.gateNextBackup()
  let engine = BackupEngine(environment: fixture.environment)
  let task = Task {
    try await engine.backup(config: testConfig()) { _ in }
  }
  var waited = 0
  while !fixture.restic.commands().contains("backup") {
    waited += 1
    if waited > 500 {
      Issue.record("backup never reached restic fake")
      break
    }
    try await Task.sleep(for: .milliseconds(2))
  }
  task.cancel()
  fixture.restic.releaseBackups()
  let record = try await task.value
  #expect(record.status == .complete)
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .size(repositoryId: "repo-1", sizeBytes: 4321),
        .end(repositoryId: "repo-1", status: .complete, durationMs: 1000),
      ])
  let logs = await fixture.deliveredLogs(engine)
  #expect(
    logs.map(\.summary)
      == [
        "Running backup",
        "Running repository prune",
        "Finished repository prune",
        "Backup finished",
      ])
}

@Test func ensureRepositoryCreationEmitsCreatedRepository() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  #expect(try await engine.ensureRepository(config: testConfig(repositoryId: nil)) == "new-repo")
  let logs = await fixture.deliveredLogs(engine)
  #expect(logs.count == 1)
  let created = try #require(logs.first)
  #expect(created.summary == "Created repository")
  #expect(created.data["repositoryId"] == .string("new-repo"))
  #expect(created.data["error"] == nil)
}

@Test func restoreEmitsStartAndFinishEventsOnSuccessAndFailure() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  try await engine.restore(
    config: testConfig(), snapshotId: "snap-1", target: URL(fileURLWithPath: "/tmp/out"), include: []
  ) { _ in }
  var logs = await fixture.deliveredLogs(engine)
  #expect(
    logs.map(\.summary)
      == ["Running repository snapshot restore", "Finished repository snapshot restore"])
  for log in logs {
    #expect(log.data["repositoryId"] == .string("repo-1"), "summary: \(log.summary)")
    #expect(log.data["snapshotId"] == .string("snap-1"), "summary: \(log.summary)")
  }
  #expect(logs[1].data["error"] == nil)

  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"restore failed"}"#),
    for: "restore")
  await #expect(throws: EngineError.restic(code: 1, message: "restore failed")) {
    try await engine.restore(
      config: testConfig(), snapshotId: "snap-2", target: URL(fileURLWithPath: "/tmp/out"), include: []
    ) { _ in }
  }
  logs = await fixture.deliveredLogs(engine)
  let failure = logs.dropFirst(2)
  #expect(
    failure.map(\.summary)
      == ["Running repository snapshot restore", "Finished repository snapshot restore"])
  let finished = try #require(failure.last)
  #expect(finished.data["snapshotId"] == .string("snap-2"))
  #expect(finished.data["error"] == .string("restore failed"))
}

@Test func snapshotsFailureEmitsListingFailureEvent() async throws {
  let fixture = makeFixture()
  fixture.restic.set(
    ResticScript(
      exitCode: 12, stderr: #"{"message_type":"exit_error","code":12,"message":"wrong password"}"#),
    for: "snapshots")
  let engine = BackupEngine(environment: fixture.environment)
  await #expect(throws: EngineError.restic(code: 12, message: "wrong password")) {
    _ = try await engine.snapshots(config: testConfig())
  }
  let logs = await fixture.deliveredLogs(engine)
  #expect(logs.count == 1)
  let log = try #require(logs.first)
  #expect(log.summary == "Failed to get repository snapshot listing")
  #expect(log.data["repositoryId"] == .string("repo-1"))
  #expect(log.data["error"] == .string("wrong password"))
}

@Test func snapshotsCancellationRethrowsWithoutListingFailureEvent() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(error: CancellationError()), for: "snapshots")
  let engine = BackupEngine(environment: fixture.environment)
  await #expect(throws: CancellationError.self) {
    _ = try await engine.snapshots(config: testConfig())
  }
  #expect(await fixture.deliveredLogs(engine).isEmpty)
}

@Test func backupCompletesAndReturnsWhileLogSendBlocksThenDeliversInOrder() async throws {
  let fixture = makeFixture()
  await fixture.api.blockLogs()
  fixture.restic.set(ResticScript(lines: backupLines), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  #expect(fixture.restic.commands() == ["version", "unlock", "backup", "forget", "stats"])
  #expect(fixture.proxy.stopCount == 1)
  await fixture.api.releaseLogs()
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .size(repositoryId: "repo-1", sizeBytes: 4321),
        .end(repositoryId: "repo-1", status: .complete, durationMs: 1000),
      ])
  let logs = await fixture.api.logs
  #expect(
    logs.map(\.summary)
      == [
        "Running backup",
        "Running repository prune",
        "Finished repository prune",
        "Backup finished",
      ])
}

@Test func outboxTimeoutDropsHangedSendAndLaterJobsStillRun() async throws {
  let fixture = makeFixture(telemetryTimeout: .milliseconds(50))
  await fixture.api.hangStructuredLogs()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  await engine.flushOutbox()
  #expect(await fixture.api.logs.isEmpty)
  #expect(
    await fixture.api.calls
      == [
        .start(repositoryId: "repo-1"),
        .size(repositoryId: "repo-1", sizeBytes: 4321),
        .end(repositoryId: "repo-1", status: .complete, durationMs: 1000),
      ])
}
