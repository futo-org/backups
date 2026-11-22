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

@Test func ensureRepositoryReturnsExistingIdWithoutCalls() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  #expect(try await engine.ensureRepository(config: testConfig()) == "repo-1")
  #expect(await fixture.api.calls.isEmpty)
  #expect(fixture.restic.commands().isEmpty)
  #expect(fixture.proxy.starts.isEmpty)
  #expect(fixture.discoverCount.value == 0)
}

@Test func ensureRepositoryCreatesInitialisesAndStopsProxy() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  let config = testConfig(repositoryId: nil)
  #expect(try await engine.ensureRepository(config: config) == "new-repo")
  #expect(await fixture.api.calls == [.create(name: "test-host")])
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
  #expect(await fixture.api.calls.isEmpty)
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
  var calls = await fixture.api.calls
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
  calls = await fixture.api.calls
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
    await fixture.api.calls == [
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
    await fixture.api.calls == [
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
  #expect(await fixture.api.calls.last == .end(repositoryId: "repo-1", status: .complete, durationMs: 1000))
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
    await fixture.api.calls == [
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
    await fixture.api.calls == [
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
    await fixture.api.calls == [
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
    await fixture.api.calls == [
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
