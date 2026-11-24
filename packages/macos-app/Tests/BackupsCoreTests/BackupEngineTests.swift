import Darwin
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
private let otherErrorLine = #"{"message_type":"error","error":{"message":"busy"},"item":"/a/c"}"#
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

@Test func backupDurationIgnoresWallClockJumpingBackwards() async throws {
  let fixture = makeFixture(clock: FixedClock(wallStep: -3600))
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.finishedAt < record.startedAt)
  #expect(
    await fixture.deliveredCalls(engine).last == .end(repositoryId: "repo-1", status: .complete, durationMs: 1000))
  let logs = await fixture.deliveredLogs(engine)
  #expect(logs.last { $0.summary == "Backup finished" }?.data["durationMs"] == .int(1000))
}

@Test(arguments: [(1, "4"), (4, "4"), (32, "32"), (128, "128"), (512, "128")])
func packSizeIsClampedToResticLimits(serverPackSize: Int, expected: String) async throws {
  let fixture = makeFixture(packSizeMiB: serverPackSize)
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  _ = try await engine.backup(config: testConfig()) { _ in }
  for command in ["backup", "forget"] {
    let invocation = try #require(fixture.restic.invocations().first { $0.arguments.first == command })
    #expect(argumentAfter(invocation.arguments, "--pack-size") == expected, "\(command)")
  }
}

@Test func backupExitThreeWarnsAndSkipsForget() async throws {
  let fixture = makeFixture()
  fixture.restic.set(
    ResticScript(
      lines: [summaryLine], exitCode: 3,
      stderr: otherErrorLine + "\n" + errorLine + "\n"
        + #"{"message_type":"exit_error","code":3,"message":"read failed"}"#),
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

@Test func backupExitThreeFallsBackToStdoutErrorThenExitError() async throws {
  let fixture = makeFixture()
  fixture.restic.set(
    ResticScript(
      lines: [errorLine], exitCode: 3,
      stderr: #"{"message_type":"exit_error","code":3,"message":"read failed"}"#),
    for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  #expect(try await engine.backup(config: testConfig()) { _ in }.message == "/a/b: permission denied")
  fixture.restic.set(
    ResticScript(exitCode: 3, stderr: #"{"message_type":"exit_error","code":3,"message":"read failed"}"#),
    for: "backup")
  #expect(try await engine.backup(config: testConfig()) { _ in }.message == "read failed")
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

@Test func backupForgetCancellationKeepsTheSavedBackupComplete() async throws {
  let fixture = makeFixture()
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(error: CancellationError()), for: "forget")
  let engine = BackupEngine(environment: fixture.environment)
  let log = ActivityLog()
  let record = try await engine.backup(config: testConfig()) { log.record($0) }
  #expect(record.status == .complete)
  #expect(record.snapshotId == "snapshot-abc")
  #expect(record.message == "Prune interrupted")
  #expect(log.all == [.preparing, .pruning])
  #expect(fixture.restic.commands() == ["version", "unlock", "backup", "forget"])
  #expect(
    await fixture.deliveredCalls(engine)
      == [
        .start(repositoryId: "repo-1"),
        .end(repositoryId: "repo-1", status: .complete, durationMs: 1000),
      ])
  let logs = await fixture.deliveredLogs(engine)
  let finishedPrune = try #require(logs.first { $0.summary == "Finished repository prune" })
  #expect(finishedPrune.data["error"] == .string("cancelled"))
  let finished = try #require(logs.last { $0.summary == "Backup finished" })
  #expect(finished.data["lastBackupStatus"] == .string("complete"))
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
    try await engine.restore(config: testConfig(), snapshotId: "snap-1", items: restoreItems) { _ in }
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

private let restoreItems = [
  RestoreItem(snapshotPath: "/Users/test/Documents", target: URL(fileURLWithPath: "/tmp/out/Documents"))
]

@Test func restoreRunsOneSubfolderRestorePerItemAndMapsFailure() async throws {
  let fixture = makeFixture()
  let engine = BackupEngine(environment: fixture.environment)
  let log = ActivityLog()
  let items = [
    RestoreItem(snapshotPath: "/Users/test/Documents", target: URL(fileURLWithPath: "/tmp/out/Documents")),
    RestoreItem(snapshotPath: "/Volumes/Work/Documents", target: URL(fileURLWithPath: "/tmp/out/Documents 2")),
  ]
  let restored = try await engine.restore(config: testConfig(), snapshotId: "snap-1", items: items) {
    log.record($0)
  }
  #expect(restored == items.map(\.target))
  #expect(log.all == [.restoring])
  let restores = fixture.restic.invocations().filter { $0.arguments.first == "restore" }
  #expect(
    restores.map { Array($0.arguments.suffix(6)) } == [
      ["--target", "/tmp/out/Documents", "--overwrite", "never", "--", "snap-1:/Users/test/Documents"],
      ["--target", "/tmp/out/Documents 2", "--overwrite", "never", "--", "snap-1:/Volumes/Work/Documents"],
    ])
  #expect(fixture.restoreDirectories.attempts == ["/tmp/out/Documents", "/tmp/out/Documents 2"])
  #expect(fixture.proxy.stopCount == 1)

  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"restore failed"}"#),
    for: "restore")
  await #expect(throws: EngineError.restic(code: 1, message: "restore failed")) {
    try await engine.restore(config: testConfig(), snapshotId: "snap-1", items: items) { _ in }
  }
  #expect(fixture.restic.invocations().filter { $0.arguments.first == "restore" }.count == 3)
  #expect(fixture.proxy.stopCount == 2)

  await #expect(throws: EngineError.noFolders) {
    try await engine.restore(config: testConfig(), snapshotId: "snap-1", items: []) { _ in }
  }
}

@Test func restoreClaimsTheNextFreeTargetWhenOneAppearedAfterPlanning() async throws {
  let fixture = makeFixture()
  fixture.restoreDirectories.add("/tmp/out/Documents")
  fixture.restoreDirectories.add("/tmp/out/Documents 3")
  let engine = BackupEngine(environment: fixture.environment)
  let items = [
    RestoreItem(snapshotPath: "/Users/test/Documents", target: URL(fileURLWithPath: "/tmp/out/Documents")),
    RestoreItem(snapshotPath: "/Volumes/Work/Documents", target: URL(fileURLWithPath: "/tmp/out/Documents 2")),
  ]
  let restored = try await engine.restore(config: testConfig(), snapshotId: "snap-1", items: items) { _ in }
  #expect(restored.map(\.path) == ["/tmp/out/Documents 2", "/tmp/out/Documents 4"])
  let targets = fixture.restic.invocations().filter { $0.arguments.first == "restore" }.map {
    argumentAfter($0.arguments, "--target")
  }
  #expect(targets == ["/tmp/out/Documents 2", "/tmp/out/Documents 4"])
  #expect(
    fixture.restoreDirectories.attempts == [
      "/tmp/out/Documents", "/tmp/out/Documents 2", "/tmp/out/Documents 3", "/tmp/out/Documents 4",
    ])
}

@Test func restoreTargetCreationFailureStopsBeforeRestic() async throws {
  let fixture = makeFixture()
  let failing = EngineEnvironment(
    secrets: fixture.environment.secrets, discover: fixture.environment.discover,
    makeAPI: fixture.environment.makeAPI, restic: fixture.restic, proxyLauncher: fixture.proxy,
    cacheDirectory: fixture.environment.cacheDirectory, home: fixture.environment.home, processorCount: 8,
    now: fixture.environment.now, createRestoreDirectory: { _ in throw POSIXError(.EACCES) })
  let engine = BackupEngine(environment: failing)
  await #expect(throws: POSIXError(.EACCES)) {
    try await engine.restore(config: testConfig(), snapshotId: "snap-1", items: restoreItems) { _ in }
  }
  #expect(!fixture.restic.commands().contains("restore"))
  #expect(fixture.proxy.stopCount == 1)
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
      try await engine.restore(config: testConfig(), snapshotId: "snap-1", items: restoreItems) { _ in }
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

@Test func macRepositoriesFiltersAndSortsThisMacFirstThenByLastBackupThenName() async throws {
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
  let thisMacOld = RemoteRepository(
    id: "this-old", name: "test-host", worm: false, lastBackup: "2026-01-01T00:00:00Z", connectionType: "macos")
  let thisMacNever = RemoteRepository(id: "this-never", name: "test-host", worm: false, connectionType: "macos")
  await fixture.api.setRepositories([older, thisMacNever, tieAlpha, thisMacOld])
  let thisMacFirst = try await engine.macRepositories(config: testConfig())
  #expect(thisMacFirst.map(\.id) == ["this-old", "this-never", "tie-alpha", "older"])
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
  try await engine.restore(config: testConfig(), snapshotId: "snap-1", items: restoreItems) { _ in }
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
    try await engine.restore(config: testConfig(), snapshotId: "snap-2", items: restoreItems) { _ in }
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

private let documentsFolder = "/Users/test/Documents"
private let externalFolder = "/Volumes/Ext/Photos"
private let cachesExclude = "/Users/test/Library/Caches"
private let snapshotDate = "2026-11-23-120000"
private let snapshotName = "com.apple.TimeMachine.\(snapshotDate).local"

private struct SnapshotFixture {
  var fixture: EngineFixture
  var snapshots: FakeDiskSnapshots
  var directory: URL
  var mountPoint: URL
  var journal: URL
  var lockFile: URL
  var config: AppConfig
}

private func makeSnapshotFixture(
  diskSnapshots: FakeDiskSnapshots = FakeDiskSnapshots(), usesSnapshotDirectory: Bool = true,
  dataVolumePath: @escaping @Sendable (String) -> String? = { path in
    path == documentsFolder ? "Users/test/Documents" : nil
  },
  cloudOnlyScanner: any CloudOnlyScanning = NoCloudOnlyScan()
) -> SnapshotFixture {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let fixture = makeFixture(
    diskSnapshots: diskSnapshots,
    snapshotDirectory: usesSnapshotDirectory ? directory : nil,
    dataVolumePath: dataVolumePath,
    cloudOnlyScanner: cloudOnlyScanner)
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  fixture.restic.set(ResticScript(stdout: statsStdout), for: "stats")
  var config = testConfig(folders: [documentsFolder, externalFolder])
  config.excludes = [cachesExclude, "**/node_modules"]
  return SnapshotFixture(
    fixture: fixture, snapshots: diskSnapshots, directory: directory,
    mountPoint: directory.appendingPathComponent("Volume"),
    journal: directory.appendingPathComponent("pending.json"),
    lockFile: directory.appendingPathComponent("lock"), config: config)
}

private func readTestJournal(_ url: URL) throws -> [DiskSnapshot] {
  guard let data = try? Data(contentsOf: url) else { return [] }
  return try JSONDecoder().decode([DiskSnapshot].self, from: data)
}

private func writeTestJournal(_ entries: [DiskSnapshot], to url: URL) throws {
  try JSONEncoder().encode(entries).write(to: url)
}

private func excludeValues(in arguments: [String]) -> [String] {
  var values: [String] = []
  var index = 0
  while index + 1 < arguments.count {
    if arguments[index] == "--exclude" {
      values.append(arguments[index + 1])
      index += 2
      continue
    }
    index += 1
  }
  return values
}

@Test func diskSnapshotBackupMountsCleansUpAndReports() async throws {
  let timeline = CallTimeline()
  let snapshots = FakeDiskSnapshots()
  snapshots.setTimeline(timeline)
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  snapshot.fixture.restic.setTimeline(timeline)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
  let mount = snapshot.mountPoint.path
  #expect(
    snapshots.calls
      == [
        "create",
        "mount \(snapshotName) \(mount)",
        "isMounted \(mount)",
        "isMounted \(mount)",
        "unmount \(mount)",
        "delete \(snapshotDate)",
      ])
  #expect(
    timeline.entries
      == [
        "version", "unlock", "create", "mount \(snapshotName) \(mount)", "isMounted \(mount)",
        "backup", "isMounted \(mount)", "unmount \(mount)", "delete \(snapshotDate)", "forget", "stats",
      ])
  let backupInvocation = try #require(
    snapshot.fixture.restic.invocations().first { $0.arguments.first == "backup" })
  #expect(backupInvocation.currentDirectory == mount)
  #expect(argumentAfter(backupInvocation.arguments, "--tag") == "disk-snapshot")
  #expect(Array(backupInvocation.arguments.suffix(2)) == ["Users/test/Documents", externalFolder])
  #expect(
    excludeValues(in: backupInvocation.arguments)
      == [cachesExclude, "**/node_modules", mount + "/Users/test/Library/Caches"])
  #expect(!FileManager.default.fileExists(atPath: snapshot.journal.path))
  let lock = try #require(SnapshotLock.acquire(at: snapshot.lockFile))
  lock.release()
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let finished = try #require(logs.last { $0.summary == "Backup finished" })
  #expect(finished.data["diskSnapshot"] == .bool(true))
}

@Test func diskSnapshotsDisabledBacksUpLiveFolders() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  var config = snapshot.config
  config.diskSnapshots = false
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: config) { _ in }
  #expect(record.status == .complete)
  #expect(snapshots.calls.isEmpty)
  let backupInvocation = try #require(
    snapshot.fixture.restic.invocations().first { $0.arguments.first == "backup" })
  #expect(backupInvocation.currentDirectory == nil)
  #expect(Array(backupInvocation.arguments.suffix(2)) == [documentsFolder, externalFolder])
  #expect(excludeValues(in: backupInvocation.arguments) == [cachesExclude, "**/node_modules"])
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let finished = try #require(logs.last { $0.summary == "Backup finished" })
  #expect(finished.data["diskSnapshot"] == .bool(false))
}

@Test func foldersOffDataVolumeSkipDiskSnapshots() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots, dataVolumePath: { _ in nil })
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
  #expect(snapshots.calls.isEmpty)
  #expect(snapshot.fixture.restic.commands() == ["version", "unlock", "backup", "forget", "stats"])
  let backupInvocation = try #require(
    snapshot.fixture.restic.invocations().first { $0.arguments.first == "backup" })
  #expect(backupInvocation.currentDirectory == nil)
  #expect(Array(backupInvocation.arguments.suffix(2)) == [documentsFolder, externalFolder])
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let finished = try #require(logs.last { $0.summary == "Backup finished" })
  #expect(finished.data["diskSnapshot"] == .bool(false))
}

@Test func diskSnapshotMountWithoutFullDiskAccessFailsRunAndDeletesSnapshot() async throws {
  let snapshots = FakeDiskSnapshots()
  snapshots.mountError = .noFullDiskAccess
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == DiskSnapshotError.noFullDiskAccess.description)
  let mount = snapshot.mountPoint.path
  #expect(
    snapshots.calls
      == [
        "create", "mount \(snapshotName) \(mount)", "isMounted \(mount)", "isMounted \(mount)",
        "delete \(snapshotDate)",
      ])
  #expect(snapshot.fixture.restic.commands() == ["version", "unlock"])
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let event = try #require(logs.first { $0.summary == "Failed to create disk snapshot" })
  #expect(event.data["repositoryId"] == .string("repo-1"))
  #expect(event.data["error"] == .string("no-full-disk-access"))
  let finished = try #require(logs.last { $0.summary == "Backup finished" })
  #expect(finished.data["error"] == .string("disk snapshot: no-full-disk-access"))
  #expect(!FileManager.default.fileExists(atPath: snapshot.journal.path))
}

@Test func diskSnapshotWithoutDirectoryFailsRun() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots, usesSnapshotDirectory: false)
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == DiskSnapshotError.unavailable.description)
  #expect(snapshots.calls.isEmpty)
  #expect(snapshot.fixture.restic.commands() == ["version", "unlock"])
}

@Test func diskSnapshotCreateFailureFailsRunAndReports() async throws {
  let snapshots = FakeDiskSnapshots()
  snapshots.createError = .createFailed("boom")
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == "Could not create a disk snapshot: boom")
  #expect(snapshots.calls == ["create"])
  #expect(snapshot.fixture.restic.commands() == ["version", "unlock"])
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let event = try #require(logs.first { $0.summary == "Failed to create disk snapshot" })
  #expect(event.data["error"] == .string("create-failed"))
}

@Test func diskSnapshotMountFailureDeletesWithoutUnmount() async throws {
  let snapshots = FakeDiskSnapshots()
  snapshots.mountError = .mountFailed("bad")
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == DiskSnapshotError.mountFailed("bad").description)
  let mount = snapshot.mountPoint.path
  #expect(
    snapshots.calls
      == [
        "create", "mount \(snapshotName) \(mount)", "isMounted \(mount)", "isMounted \(mount)",
        "delete \(snapshotDate)",
      ])
  #expect(!FileManager.default.fileExists(atPath: snapshot.journal.path))
}

@Test func cancelledDiskSnapshotBackupStillCleansUp() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  snapshot.fixture.restic.gateNextBackup(checkingCancellation: true)
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let task = Task {
    try await engine.backup(config: snapshot.config) { _ in }
  }
  var waited = 0
  while !snapshot.fixture.restic.commands().contains("backup") {
    waited += 1
    if waited > 500 {
      Issue.record("backup never reached restic fake")
      break
    }
    try await Task.sleep(for: .milliseconds(2))
  }
  task.cancel()
  snapshot.fixture.restic.releaseBackups()
  let record = try await task.value
  #expect(record.status == .cancelled)
  let mount = snapshot.mountPoint.path
  #expect(
    snapshots.calls
      == [
        "create", "mount \(snapshotName) \(mount)", "isMounted \(mount)", "isMounted \(mount)",
        "unmount \(mount)", "delete \(snapshotDate)",
      ])
}

@Test func diskSnapshotDeleteFailureKeepsCompleteAndJournal() async throws {
  let snapshots = FakeDiskSnapshots()
  snapshots.deleteError = .deleteFailed("busy")
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let event = try #require(logs.first { $0.summary == "Failed to remove disk snapshot" })
  #expect(event.data["repositoryId"] == .string("repo-1"))
  #expect(event.data["error"] == .string("delete-failed"))
  #expect(try readTestJournal(snapshot.journal) == [DiskSnapshot(date: snapshotDate)])
}

@Test func staleDiskSnapshotCleanedUpBeforeCreate() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  try writeTestJournal([DiskSnapshot(date: "2026-01-01-000000")], to: snapshot.journal)
  snapshots.mountedNames = [
    snapshot.mountPoint.path: DiskSnapshot(date: "2026-01-01-000000").name
  ]
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
  let mount = snapshot.mountPoint.path
  #expect(
    Array(snapshots.calls.prefix(4))
      == ["isMounted \(mount)", "unmount \(mount)", "delete 2026-01-01-000000", "create"])
}

@Test func snapshotsMapsSnapshotPathsToLivePaths() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let mount = directory.appendingPathComponent("Volume").path
  let json = """
    [{"id":"a","short_id":"a","time":"2026-11-23T12:00:00Z","hostname":"test-host",\
    "tags":["disk-snapshot"],"paths":["\(mount)/Users/test/Documents","/Volumes/Ext/Photos","\(mount)"]}]
    """
  let withDirectory = makeFixture(snapshotDirectory: directory)
  withDirectory.restic.set(ResticScript(stdout: json), for: "snapshots")
  let mapped = try await BackupEngine(environment: withDirectory.environment)
    .snapshots(config: testConfig())
  #expect(mapped.map(\.paths) == [["/Users/test/Documents", "/Volumes/Ext/Photos", "/"]])
  let withoutDirectory = makeFixture()
  withoutDirectory.restic.set(ResticScript(stdout: json), for: "snapshots")
  let unchanged = try await BackupEngine(environment: withoutDirectory.environment)
    .snapshots(config: testConfig())
  #expect(
    unchanged.map(\.paths) == [["\(mount)/Users/test/Documents", "/Volumes/Ext/Photos", mount]])
}

@Test(arguments: [nil, URL(fileURLWithPath: "/Users/test/Library/Application Support/FUTO Backups/Snapshot")])
func snapshotsMapsAnotherMacsSnapshotMountToLivePaths(snapshotDirectory: URL?) async throws {
  let aliceMount = "/Users/alice/Library/Application Support/FUTO Backups/Snapshot/Volume"
  let resolvedMount =
    "/private/var/root/Library/Containers/x/Data/Library/Application Support/FUTO Backups/Snapshot/Volume"
  let json = """
    [{"id":"tagged","short_id":"tagged","time":"2026-11-23T12:00:00Z","hostname":"alice-mac",\
    "tags":["disk-snapshot"],"paths":["\(aliceMount)/Users/alice/Docs","\(aliceMount)",\
    "\(resolvedMount)/Users/alice/Mom's Taxes, 2025","/Volumes/Ext/Photos","\(aliceMount)2/Users/alice/Docs"]},\
    {"id":"untagged","short_id":"untagged","time":"2026-11-22T12:00:00Z","hostname":"alice-mac",\
    "paths":["\(aliceMount)/Users/alice/Docs"]}]
    """
  let fixture = makeFixture(snapshotDirectory: snapshotDirectory)
  fixture.restic.set(ResticScript(stdout: json), for: "snapshots")
  let listed = try await BackupEngine(environment: fixture.environment).snapshots(config: testConfig())
  let tagged = try #require(listed.first { $0.id == "tagged" })
  #expect(
    tagged.paths == [
      "/Users/alice/Docs", "/", "/Users/alice/Mom's Taxes, 2025", "/Volumes/Ext/Photos",
      "\(aliceMount)2/Users/alice/Docs",
    ])
  let untagged = try #require(listed.first { $0.id == "untagged" })
  #expect(untagged.paths == ["\(aliceMount)/Users/alice/Docs"])
}

private func waitForSnapshotCall(_ snapshots: FakeDiskSnapshots, prefix: String) async {
  var waited = 0
  while !snapshots.calls.contains(where: { $0.hasPrefix(prefix) }) {
    waited += 1
    if waited > 500 {
      Issue.record("backup never reached snapshot fake at \(prefix)")
      break
    }
    try? await Task.sleep(for: .milliseconds(2))
  }
}

@Test func cancelledDiskSnapshotCreateStillDeletesCreatedSnapshot() async throws {
  let snapshots = FakeDiskSnapshots()
  snapshots.gateNextCreate()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let task = Task {
    try await engine.backup(config: snapshot.config) { _ in }
  }
  await waitForSnapshotCall(snapshots, prefix: "create")
  task.cancel()
  snapshots.releaseCreates()
  let record = try await task.value
  #expect(record.status == .cancelled)
  let mount = snapshot.mountPoint.path
  #expect(snapshots.calls == ["create", "isMounted \(mount)", "delete \(snapshotDate)"])
  #expect(snapshot.fixture.restic.commands() == ["version", "unlock"])
  #expect(try readTestJournal(snapshot.journal).isEmpty)
  let logs = await snapshot.fixture.deliveredLogs(engine)
  #expect(logs.first { $0.summary == "Failed to create disk snapshot" } == nil)
}

@Test func cancelledDiskSnapshotMountUnmountsAndDeletes() async throws {
  let snapshots = FakeDiskSnapshots()
  snapshots.gateNextMount()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let task = Task {
    try await engine.backup(config: snapshot.config) { _ in }
  }
  await waitForSnapshotCall(snapshots, prefix: "mount ")
  task.cancel()
  snapshots.releaseMounts()
  let record = try await task.value
  #expect(record.status == .cancelled)
  let mount = snapshot.mountPoint.path
  #expect(
    snapshots.calls
      == [
        "create", "mount \(snapshotName) \(mount)", "isMounted \(mount)", "isMounted \(mount)",
        "unmount \(mount)", "delete \(snapshotDate)",
      ])
  #expect(try readTestJournal(snapshot.journal).isEmpty)
}

@Test func diskSnapshotMountFailureStillUnmountsWhenSnapshotIsMounted() async throws {
  let snapshots = FakeDiskSnapshots()
  snapshots.mountError = .mountFailed("slow failure")
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  snapshots.mountedNames = [snapshot.mountPoint.path: snapshotName]
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == DiskSnapshotError.mountFailed("slow failure").description)
  let mount = snapshot.mountPoint.path
  #expect(
    snapshots.calls
      == [
        "create", "mount \(snapshotName) \(mount)", "isMounted \(mount)", "isMounted \(mount)",
        "unmount \(mount)", "delete \(snapshotDate)",
      ])
}

@Test func journalWriteFailureFailsSetupAndDeletesSnapshot() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  try Data().write(to: snapshot.lockFile)
  chflags(snapshot.directory.path, UInt32(bitPattern: Int32(UF_IMMUTABLE)))
  defer {
    chflags(snapshot.directory.path, 0)
    try? FileManager.default.removeItem(at: snapshot.directory)
  }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(
    record.message == DiskSnapshotError.createFailed("could not record the snapshot").description)
  let mount = snapshot.mountPoint.path
  #expect(snapshots.calls == ["create", "isMounted \(mount)", "delete \(snapshotDate)"])
  #expect(snapshot.fixture.restic.commands() == ["version", "unlock"])
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let event = try #require(logs.first { $0.summary == "Failed to create disk snapshot" })
  #expect(event.data["error"] == .string("create-failed"))
}

@Test(arguments: [Data("not json".utf8), Data(#"[{"date":"bad"}]"#.utf8), nil])
func unreadableJournalFailsSetupBeforeCreateAndKeepsTheFile(contents: Data?) async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  if let contents {
    try contents.write(to: snapshot.journal)
  } else {
    try FileManager.default.createDirectory(at: snapshot.journal, withIntermediateDirectories: false)
  }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == DiskSnapshotError.journalUnreadable.description)
  #expect(snapshots.calls.isEmpty)
  #expect(snapshot.fixture.restic.commands() == ["version", "unlock"])
  if let contents {
    #expect(try Data(contentsOf: snapshot.journal) == contents)
  } else {
    #expect(FileManager.default.fileExists(atPath: snapshot.journal.path))
  }
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let staleEvent = try #require(logs.first { $0.summary == "Failed to remove disk snapshot" })
  #expect(staleEvent.data["error"] == .string("journal-unreadable"))
  let createEvent = try #require(logs.first { $0.summary == "Failed to create disk snapshot" })
  #expect(createEvent.data["error"] == .string("journal-unreadable"))
  let finished = try #require(logs.last { $0.summary == "Backup finished" })
  #expect(finished.data["error"] == .string("disk snapshot: journal-unreadable"))
}

@Test func journalCorruptedDuringTheRunIsKeptAndReported() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  snapshot.fixture.restic.gateNextBackup()
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let task = Task {
    try await engine.backup(config: snapshot.config) { _ in }
  }
  var waited = 0
  while !snapshot.fixture.restic.commands().contains("backup") {
    waited += 1
    if waited > 500 {
      Issue.record("backup never reached restic fake")
      break
    }
    try await Task.sleep(for: .milliseconds(2))
  }
  try Data("not json".utf8).write(to: snapshot.journal)
  snapshot.fixture.restic.releaseBackups()
  let record = try await task.value
  #expect(record.status == .complete)
  #expect(try Data(contentsOf: snapshot.journal) == Data("not json".utf8))
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let event = try #require(logs.first { $0.summary == "Failed to remove disk snapshot" })
  #expect(event.data["error"] == .string("journal-unreadable"))
}

@Test func unreadableJournalSkipsStaleCleanupAndKeepsTheFile() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  try Data("not json".utf8).write(to: snapshot.journal)
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  await engine.cleanUpStaleDiskSnapshots()
  #expect(snapshots.calls.isEmpty)
  #expect(try Data(contentsOf: snapshot.journal) == Data("not json".utf8))
}

@Test func staleDeleteFailureKeepsEntryAndReportsDeleteCode() async throws {
  let snapshots = FakeDiskSnapshots()
  let stale = DiskSnapshot(date: "2026-01-01-000000")
  snapshots.deleteErrors = [stale.date: .deleteFailed("busy")]
  snapshots.extraExistingDates = [stale.date]
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  try writeTestJournal([stale], to: snapshot.journal)
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let event = try #require(logs.first { $0.summary == "Failed to remove disk snapshot" })
  #expect(event.data["repositoryId"] == .string("repo-1"))
  #expect(event.data["error"] == .string("delete-failed"))
  #expect(try readTestJournal(snapshot.journal) == [stale])
}

@Test func staleEntryAlreadyPurgedDropsFromJournalWithoutFailureEvent() async throws {
  let snapshots = FakeDiskSnapshots()
  let stale = DiskSnapshot(date: "2026-01-01-000000")
  snapshots.deleteErrors = [stale.date: .deleteFailed("gone")]
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  try writeTestJournal([stale], to: snapshot.journal)
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
  let logs = await snapshot.fixture.deliveredLogs(engine)
  #expect(logs.first { $0.summary == "Failed to remove disk snapshot" } == nil)
  #expect(try readTestJournal(snapshot.journal).isEmpty)
}

@Test func staleMountNotInJournalIsNotUnmounted() async throws {
  let snapshots = FakeDiskSnapshots()
  let stale = DiskSnapshot(date: "2026-01-01-000000")
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  try writeTestJournal([stale], to: snapshot.journal)
  snapshots.mountedNames = [snapshot.mountPoint.path: "something-else"]
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  await engine.cleanUpStaleDiskSnapshots()
  let mount = snapshot.mountPoint.path
  #expect(snapshots.calls == ["isMounted \(mount)", "delete 2026-01-01-000000"])
  #expect(try readTestJournal(snapshot.journal).isEmpty)
}

@Test func busySnapshotLockFailsRunBeforeCreate() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  let lock = try #require(SnapshotLock.acquire(at: snapshot.lockFile))
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(
    record.message
      == DiskSnapshotError.createFailed("another backup is using disk snapshots").description)
  #expect(snapshots.calls.isEmpty)
  #expect(snapshot.fixture.restic.commands() == ["version", "unlock"])
  lock.release()
}

@Test func cleanUpStaleDiskSnapshotsDeletesRemovesJournalAndReleasesLock() async throws {
  let snapshots = FakeDiskSnapshots()
  let stale = DiskSnapshot(date: "2026-01-01-000000")
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.directory, withIntermediateDirectories: true)
  try writeTestJournal([stale], to: snapshot.journal)
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  await engine.cleanUpStaleDiskSnapshots()
  let mount = snapshot.mountPoint.path
  #expect(snapshots.calls == ["isMounted \(mount)", "delete 2026-01-01-000000"])
  #expect(!FileManager.default.fileExists(atPath: snapshot.journal.path))
  #expect(FileManager.default.fileExists(atPath: snapshot.lockFile.path))
  let lock = try #require(SnapshotLock.acquire(at: snapshot.lockFile))
  lock.release()
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
}

@Test func diskSnapshotTelemetryCarriesCodesInsteadOfDetails() async throws {
  let snapshots = FakeDiskSnapshots()
  snapshots.createError = .createFailed("/Users/x/secret")
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == "Could not create a disk snapshot: /Users/x/secret")
  let logs = await snapshot.fixture.deliveredLogs(engine)
  let event = try #require(logs.first { $0.summary == "Failed to create disk snapshot" })
  #expect(event.data["error"] == .string("create-failed"))
  let finished = try #require(logs.last { $0.summary == "Backup finished" })
  #expect(finished.data["error"] == .string("disk snapshot: create-failed"))
  for log in logs {
    for value in log.data.values {
      if case .string(let text) = value {
        #expect(!text.contains("/Users/x/secret"), "summary: \(log.summary)")
      }
    }
  }
}

@Test func diskSnapshotRunAndListingUseResolvedMountSpelling() async throws {
  let snapshots = FakeDiskSnapshots()
  let snapshot = makeSnapshotFixture(diskSnapshots: snapshots)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  try FileManager.default.createDirectory(at: snapshot.mountPoint, withIntermediateDirectories: true)
  let resolved = DataVolume.resolvedPath(snapshot.mountPoint.path)
  #expect(resolved.hasPrefix("/private/var/"))
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
  let backupInvocation = try #require(
    snapshot.fixture.restic.invocations().first { $0.arguments.first == "backup" })
  #expect(backupInvocation.currentDirectory == resolved)
  #expect(
    excludeValues(in: backupInvocation.arguments)
      == [cachesExclude, "**/node_modules", resolved + "/Users/test/Library/Caches"])
  #expect(argumentAfter(backupInvocation.arguments, "--tag") == "disk-snapshot")
  let json = """
    [{"id":"tagged","short_id":"tagged","time":"2026-11-23T12:00:00Z","hostname":"test-host",\
    "tags":["disk-snapshot"],"paths":["\(snapshot.mountPoint.path)/Users/test/Documents",\
    "\(resolved)/Users/test/Docs","\(snapshot.mountPoint.path)","\(resolved)"]},\
    {"id":"untagged","short_id":"untagged","time":"2026-11-22T12:00:00Z","hostname":"test-host",\
    "paths":["\(snapshot.mountPoint.path)/Users/other/Secret"]}]
    """
  snapshot.fixture.restic.set(ResticScript(stdout: json), for: "snapshots")
  let listed = try await engine.snapshots(config: snapshot.config)
  let tagged = try #require(listed.first { $0.id == "tagged" })
  #expect(tagged.paths == ["/Users/test/Documents", "/Users/test/Docs", "/", "/"])
  let untagged = try #require(listed.first { $0.id == "untagged" })
  #expect(untagged.paths == ["\(snapshot.mountPoint.path)/Users/other/Secret"])
}

private let skippedFiles = CloudOnlySkip(
  count: 12, bytes: 340_000_000, sample: ["/Users/test/Documents/ws.pptx", "/Users/test/Documents/talk.key"])

@Test func backupRecordsCloudOnlySkipsAndReportsOnlyTheirCountAndSize() async throws {
  let scanner = FakeCloudOnlyScanner(result: skippedFiles)
  let fixture = makeFixture(cloudOnlyScanner: scanner)
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  var config = testConfig(folders: ["/Users/test/Documents"])
  config.excludes = ["**/node_modules"]
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: config) { _ in }
  #expect(record.status == .complete)
  #expect(record.message == nil)
  #expect(record.cloudOnlySkipped == skippedFiles)
  #expect(scanner.calls == [CloudOnlyScanCall(folders: ["/Users/test/Documents"], excludes: ["**/node_modules"])])
  let backupArgs = try #require(fixture.restic.invocations().first { $0.arguments.first == "backup" }).arguments
  #expect(backupArgs.contains("--exclude-cloud-files"))
  let finished = try #require(await fixture.deliveredLogs(engine).last { $0.summary == "Backup finished" })
  #expect(finished.data["lastBackupStatus"] == .string("complete"))
  #expect(finished.data["cloudOnlyFiles"] == .int(12))
  #expect(finished.data["cloudOnlySize"] == .string("<1GB"))
  let encoded = String(decoding: try JSONEncoder().encode(finished), as: UTF8.self)
  #expect(!encoded.contains("ws.pptx"))
  #expect(!encoded.contains("talk.key"))
}

@Test func backupWithoutCloudOnlyFilesStoresNoSkipButReportsZero() async throws {
  let fixture = makeFixture(cloudOnlyScanner: FakeCloudOnlyScanner(result: CloudOnlySkip()))
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  #expect(record.cloudOnlySkipped == nil)
  let finished = try #require(await fixture.deliveredLogs(engine).last { $0.summary == "Backup finished" })
  #expect(finished.data["cloudOnlyFiles"] == .int(0))
  #expect(finished.data["cloudOnlySize"] == .string("0"))
}

@Test func failedCloudOnlyScanLeavesTheBackupResultAlone() async throws {
  let fixture = makeFixture(cloudOnlyScanner: FakeCloudOnlyScanner(result: nil))
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .complete)
  #expect(record.cloudOnlySkipped == nil)
  let finished = try #require(await fixture.deliveredLogs(engine).last { $0.summary == "Backup finished" })
  #expect(finished.data["cloudOnlyFiles"] == nil)
  #expect(finished.data["cloudOnlySize"] == nil)
}

@Test func failedBackupCancelsTheCloudOnlyScan() async throws {
  let scanner = FakeCloudOnlyScanner(hangs: true)
  let fixture = makeFixture(cloudOnlyScanner: scanner)
  fixture.restic.set(
    ResticScript(exitCode: 1, stderr: #"{"message_type":"exit_error","code":1,"message":"no space"}"#),
    for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig()) { _ in }
  #expect(record.status == .failed)
  #expect(record.cloudOnlySkipped == nil)
  for _ in 0..<200 where !scanner.cancelled {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(scanner.cancelled)
}

@Test func cancellingTheBackupWhileTheScanRunsCancelsTheScan() async throws {
  let scanner = FakeCloudOnlyScanner(hangs: true)
  let fixture = makeFixture(cloudOnlyScanner: scanner)
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  let engine = BackupEngine(environment: fixture.environment)
  let task = Task { try await engine.backup(config: testConfig()) { _ in } }
  for _ in 0..<400 where !fixture.restic.commands().contains("stats") {
    try await Task.sleep(for: .milliseconds(5))
  }
  task.cancel()
  let record = try await task.value
  #expect(record.status == .complete)
  #expect(record.cloudOnlySkipped == nil)
  #expect(scanner.cancelled)
}

@Test func cloudOnlyFolderIsLeftOutOfTheBackupTargets() async throws {
  let scanner = FakeCloudOnlyScanner(
    cloudOnly: ["/Users/test/Desktop"],
    result: CloudOnlySkip(count: 1, sample: ["/Users/test/Desktop/"]))
  let fixture = makeFixture(cloudOnlyScanner: scanner)
  fixture.restic.set(ResticScript(lines: [summaryLine]), for: "backup")
  let config = testConfig(folders: ["/Users/test/Desktop", "/Users/test/Documents"])
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: config) { _ in }
  #expect(record.status == .complete)
  #expect(record.cloudOnlySkipped?.sample == ["/Users/test/Desktop/"])
  let backupArgs = try #require(fixture.restic.invocations().first { $0.arguments.first == "backup" }).arguments
  #expect(Array(backupArgs.suffix(2)) == ["--", "/Users/test/Documents"])
  #expect(scanner.calls.map(\.folders) == [["/Users/test/Desktop", "/Users/test/Documents"]])
}

@Test func cloudOnlyFolderIsLeftOutOfDiskSnapshotTargetsAndScanUsesLiveFolders() async throws {
  let scanner = FakeCloudOnlyScanner(cloudOnly: [externalFolder], result: skippedFiles)
  let snapshot = makeSnapshotFixture(cloudOnlyScanner: scanner)
  defer { try? FileManager.default.removeItem(at: snapshot.directory) }
  let engine = BackupEngine(environment: snapshot.fixture.environment)
  let record = try await engine.backup(config: snapshot.config) { _ in }
  #expect(record.status == .complete)
  #expect(record.cloudOnlySkipped == skippedFiles)
  let backupInvocation = try #require(
    snapshot.fixture.restic.invocations().first { $0.arguments.first == "backup" })
  #expect(argumentAfter(backupInvocation.arguments, "--tag") == "disk-snapshot")
  #expect(backupInvocation.arguments.contains("--exclude-cloud-files"))
  #expect(Array(backupInvocation.arguments.suffix(2)) == ["--", "Users/test/Documents"])
  #expect(
    scanner.calls
      == [CloudOnlyScanCall(folders: [documentsFolder, externalFolder], excludes: snapshot.config.excludes)])
}

@Test func everyFolderCloudOnlyFailsWithoutRunningResticBackupAndReportsTheSkip() async throws {
  let skip = CloudOnlySkip(count: 1, sample: ["/Users/test/Desktop/"])
  let scanner = FakeCloudOnlyScanner(cloudOnly: ["/Users/test/Desktop"], result: skip)
  let fixture = makeFixture(cloudOnlyScanner: scanner)
  let engine = BackupEngine(environment: fixture.environment)
  let record = try await engine.backup(config: testConfig(folders: ["/Users/test/Desktop"])) { _ in }
  #expect(record.status == .failed)
  #expect(record.message == CloudOnlyError.everyFolderIsCloudOnly.description)
  #expect(record.cloudOnlySkipped == skip)
  #expect(fixture.restic.commands() == ["version", "unlock"])
  #expect(fixture.proxy.stopCount == 1)
}
