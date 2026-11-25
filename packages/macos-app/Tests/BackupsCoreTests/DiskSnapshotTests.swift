import Darwin
import Foundation
import Testing

@testable import BackupsCore

private final class ScriptedRunner: ResticExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private var script: [ResticResult]
  private var index = 0
  private var recorded: [ResticInvocation] = []

  init(script: [ResticResult]) {
    self.script = script
  }

  func run(_ invocation: ResticInvocation, onLine: @escaping @Sendable (String) -> Void) async throws
    -> ResticResult
  {
    lock.withLock {
      recorded.append(invocation)
      let result = script[min(index, script.count - 1)]
      index += 1
      return result
    }
  }

  var invocations: [ResticInvocation] {
    lock.withLock { recorded }
  }
}

private final class Gate: @unchecked Sendable {
  private let condition = NSCondition()
  private var open = false

  func wait() {
    condition.lock()
    while !open {
      condition.wait()
    }
    condition.unlock()
  }

  func signal() {
    condition.lock()
    open = true
    condition.broadcast()
    condition.unlock()
  }
}

private struct HangingRunner: ResticExecuting {
  var sleep: Duration = .seconds(60)
  var gate: Gate?

  func run(_ invocation: ResticInvocation, onLine: @escaping @Sendable (String) -> Void) async throws
    -> ResticResult
  {
    if let gate {
      gate.wait()
      return result()
    }
    try await Task.sleep(for: sleep)
    return result()
  }
}

private func result(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") -> ResticResult {
  ResticResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: stderr)
}

private let snapshotDate = "2026-11-23-112124"
private let snapshotName = "com.apple.TimeMachine.2026-11-23-112124.local"
private let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"
private let createOutput =
  "NOTE: local snapshots are considered purgeable...\nCreated local snapshot with date: 2026-11-23-112124\n"

private func makeSnapshots(
  tmutil: ScriptedRunner = ScriptedRunner(script: [result()]),
  mountAPFS: ScriptedRunner = ScriptedRunner(script: [result()]),
  umount: ScriptedRunner = ScriptedRunner(script: [result()]),
  timeout: Duration = .seconds(120)
) -> (TimeMachineSnapshots, ScriptedRunner, ScriptedRunner, ScriptedRunner) {
  (
    TimeMachineSnapshots(tmutil: tmutil, mountAPFS: mountAPFS, umount: umount, timeout: timeout),
    tmutil, mountAPFS, umount
  )
}

private func freshMountPoint() -> (base: URL, mountPoint: URL) {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  return (base, base.appendingPathComponent("Volume"))
}

private func mode(of path: String) -> mode_t {
  var info = stat()
  guard stat(path, &info) == 0 else { return 0 }
  return info.st_mode & 0o777
}

private func mountSource(of status: statfs) -> String {
  withUnsafePointer(to: status.f_mntfromname) { tuple in
    tuple.withMemoryRebound(to: CChar.self, capacity: 1024) { bytes in
      String(cString: bytes)
    }
  }
}

@Test func createRunsLocalsnapshotAndParsesDate() async throws {
  let (snapshots, tmutil, mountAPFS, umount) = makeSnapshots(
    tmutil: ScriptedRunner(script: [result(stdout: createOutput)]))
  let snapshot = try await snapshots.create()
  #expect(snapshot.date == snapshotDate)
  #expect(snapshot.name == snapshotName)
  #expect(tmutil.invocations == [ResticInvocation(arguments: ["localsnapshot"], environment: ["PATH": systemPath])])
  #expect(mountAPFS.invocations.isEmpty)
  #expect(umount.invocations.isEmpty)
}

@Test(
  "create failures",
  arguments: [
    (result: result(exitCode: 1, stderr: "  boom\n"), expected: DiskSnapshotError.createFailed("boom")),
    (result: result(stdout: "something else\n"), expected: DiskSnapshotError.createFailed("something else")),
    (result: result(exitCode: 3), expected: DiskSnapshotError.createFailed("exit code 3")),
  ])
func createFailures(script: ResticResult, expected: DiskSnapshotError) async {
  let (snapshots, _, _, _) = makeSnapshots(tmutil: ScriptedRunner(script: [script]))
  await #expect(throws: expected) {
    _ = try await snapshots.create()
  }
}

@Test func mountCreatesDirectoryAndRunsMountAPFS() async throws {
  let (base, mountPoint) = freshMountPoint()
  defer { try? FileManager.default.removeItem(at: base) }
  let (snapshots, tmutil, mountAPFS, umount) = makeSnapshots()
  try await snapshots.mount(DiskSnapshot(date: snapshotDate), at: mountPoint)
  var isDirectory: ObjCBool = false
  #expect(FileManager.default.fileExists(atPath: mountPoint.path, isDirectory: &isDirectory) && isDirectory.boolValue)
  #expect(
    mountAPFS.invocations
      == [
        ResticInvocation(
          arguments: ["-o", "ro,nobrowse", "-s", snapshotName, "/System/Volumes/Data", mountPoint.path],
          environment: ["PATH": systemPath])
      ])
  #expect(tmutil.invocations.isEmpty)
  #expect(umount.invocations.isEmpty)
}

@Test(
  "mount failures",
  arguments: [
    (
      result: result(exitCode: 77, stderr: "mount_apfs: volume could not be mounted: Operation not permitted"),
      expected: DiskSnapshotError.noFullDiskAccess
    ),
    (result: result(exitCode: 1, stderr: "other"), expected: DiskSnapshotError.mountFailed("other")),
  ])
func mountFailures(script: ResticResult, expected: DiskSnapshotError) async {
  let (base, mountPoint) = freshMountPoint()
  defer { try? FileManager.default.removeItem(at: base) }
  let (snapshots, _, _, _) = makeSnapshots(mountAPFS: ScriptedRunner(script: [script]))
  await #expect(throws: expected) {
    try await snapshots.mount(DiskSnapshot(date: snapshotDate), at: mountPoint)
  }
}

@Test func unmountSucceedsWithSingleInvocation() async throws {
  let mountPath = "/Volumes/FutoSnapshotTest/\(UUID().uuidString)"
  let (snapshots, _, _, umount) = makeSnapshots()
  try await snapshots.unmount(URL(fileURLWithPath: mountPath))
  #expect(umount.invocations == [ResticInvocation(arguments: [mountPath], environment: ["PATH": systemPath])])
}

@Test func unmountRetriesWithForceAndSucceeds() async throws {
  let mountPath = "/Volumes/FutoSnapshotTest/\(UUID().uuidString)"
  let (snapshots, _, _, umount) = makeSnapshots(
    umount: ScriptedRunner(script: [result(exitCode: 1, stderr: "Resource busy"), result()]))
  try await snapshots.unmount(URL(fileURLWithPath: mountPath))
  #expect(
    umount.invocations
      == [
        ResticInvocation(arguments: [mountPath], environment: ["PATH": systemPath]),
        ResticInvocation(arguments: ["-f", mountPath], environment: ["PATH": systemPath]),
      ])
}

@Test func unmountFailureThrowsSecondDetail() async {
  let mountPath = "/Volumes/FutoSnapshotTest/\(UUID().uuidString)"
  let (snapshots, _, _, umount) = makeSnapshots(
    umount: ScriptedRunner(script: [result(exitCode: 1, stderr: "first"), result(exitCode: 32, stderr: "busy")]))
  await #expect(throws: DiskSnapshotError.unmountFailed("busy")) {
    try await snapshots.unmount(URL(fileURLWithPath: mountPath))
  }
  #expect(umount.invocations.count == 2)
}

@Test func deleteRunsDeletelocalsnapshots() async throws {
  let (snapshots, tmutil, mountAPFS, umount) = makeSnapshots()
  try await snapshots.delete(DiskSnapshot(date: snapshotDate))
  #expect(
    tmutil.invocations
      == [ResticInvocation(arguments: ["deletelocalsnapshots", snapshotDate], environment: ["PATH": systemPath])])
  #expect(mountAPFS.invocations.isEmpty)
  #expect(umount.invocations.isEmpty)
}

@Test func deleteFailureThrows() async {
  let (snapshots, _, _, _) = makeSnapshots(tmutil: ScriptedRunner(script: [result(exitCode: 2, stderr: "gone")]))
  await #expect(throws: DiskSnapshotError.deleteFailed("gone")) {
    try await snapshots.delete(DiskSnapshot(date: snapshotDate))
  }
}

@Test func deleteRejectsInvalidDateWithoutRunning() async {
  let (snapshots, tmutil, mountAPFS, umount) = makeSnapshots()
  await #expect(throws: DiskSnapshotError.deleteFailed("invalid snapshot date")) {
    try await snapshots.delete(DiskSnapshot(date: "--all"))
  }
  #expect(tmutil.invocations.isEmpty)
  #expect(mountAPFS.invocations.isEmpty)
  #expect(umount.invocations.isEmpty)
}

@Test func existingSnapshotDatesParsesPublishedOutput() async throws {
  let (snapshots, tmutil, mountAPFS, umount) = makeSnapshots(
    tmutil: ScriptedRunner(script: [result(stdout: "Snapshot dates for disk /:\n2026-11-23-112124\n")]))
  let dates = try await snapshots.existingSnapshotDates()
  #expect(dates == [snapshotDate])
  #expect(
    tmutil.invocations
      == [
        ResticInvocation(
          arguments: ["listlocalsnapshotdates", "/"], environment: ["PATH": systemPath])
      ])
  #expect(mountAPFS.invocations.isEmpty)
  #expect(umount.invocations.isEmpty)
}

@Test func existingSnapshotDatesIgnoresHeaderAndInvalidLines() async throws {
  let output = """
    Snapshot dates for disk /:
    2026-11-23-112124
    2026-11-23-112124x
    x2026-11-23-112124
    2026-11-23

      2026-11-23-112125
    """
  let (snapshots, _, _, _) = makeSnapshots(
    tmutil: ScriptedRunner(script: [result(stdout: output)]))
  #expect(try await snapshots.existingSnapshotDates() == [snapshotDate, "2026-11-23-112125"])
}

@Test func existingSnapshotDatesFailureThrowsDeleteFailed() async {
  let (snapshots, _, _, _) = makeSnapshots(
    tmutil: ScriptedRunner(script: [result(exitCode: 1, stderr: "denied")]))
  await #expect(throws: DiskSnapshotError.deleteFailed("denied")) {
    _ = try await snapshots.existingSnapshotDates()
  }
}

@Test func eachRunnerReceivesOnlyItsOwnCommands() async throws {
  let (base, mountPoint) = freshMountPoint()
  defer { try? FileManager.default.removeItem(at: base) }
  let (snapshots, tmutil, mountAPFS, umount) = makeSnapshots(
    tmutil: ScriptedRunner(script: [result(stdout: createOutput), result()]),
    mountAPFS: ScriptedRunner(script: [result()]),
    umount: ScriptedRunner(script: [result()])
  )
  let snapshot = try await snapshots.create()
  try await snapshots.mount(snapshot, at: mountPoint)
  try await snapshots.unmount(mountPoint)
  try await snapshots.delete(snapshot)
  #expect(
    tmutil.invocations.map(\.arguments)
      == [["localsnapshot"], ["deletelocalsnapshots", snapshotDate]])
  #expect(
    mountAPFS.invocations.map(\.arguments)
      == [["-o", "ro,nobrowse", "-s", snapshotName, "/System/Volumes/Data", mountPoint.path]])
  #expect(umount.invocations.map(\.arguments) == [[mountPoint.path]])
}

@Test(
  "disk snapshot error descriptions",
  arguments: [
    (DiskSnapshotError.unavailable, "Disk snapshots are unavailable."),
    (
      DiskSnapshotError.noFullDiskAccess,
      "Backing up from a disk snapshot needs Full Disk Access. Grant it in System Settings, or turn off disk snapshots in Settings."
    ),
    (DiskSnapshotError.createFailed("boom"), "Could not create a disk snapshot: boom"),
    (DiskSnapshotError.mountFailed("boom"), "Could not open the disk snapshot: boom"),
    (DiskSnapshotError.unmountFailed("boom"), "Could not close the disk snapshot: boom"),
    (DiskSnapshotError.deleteFailed("boom"), "Could not delete the disk snapshot: boom"),
    (
      DiskSnapshotError.journalUnreadable,
      "Could not read the record of pending disk snapshots. Turn off disk snapshots in Settings to back up without them."
    ),
  ])
func errorDescriptions(error: DiskSnapshotError, expected: String) {
  #expect(error.description == expected)
}

@Test(
  "disk snapshot error telemetry codes",
  arguments: [
    (DiskSnapshotError.unavailable, "unavailable"),
    (DiskSnapshotError.noFullDiskAccess, "no-full-disk-access"),
    (DiskSnapshotError.createFailed("boom"), "create-failed"),
    (DiskSnapshotError.mountFailed("boom"), "mount-failed"),
    (DiskSnapshotError.unmountFailed("boom"), "unmount-failed"),
    (DiskSnapshotError.deleteFailed("boom"), "delete-failed"),
    (DiskSnapshotError.journalUnreadable, "journal-unreadable"),
  ])
func errorTelemetryCodes(error: DiskSnapshotError, expected: String) {
  #expect(error.telemetryCode == expected)
}

@Test func unavailableDiskSnapshotsThrowsAndReportsNoName() async {
  let snapshots = UnavailableDiskSnapshots()
  await #expect(throws: DiskSnapshotError.unavailable) {
    _ = try await snapshots.create()
  }
  await #expect(throws: DiskSnapshotError.unavailable) {
    try await snapshots.mount(DiskSnapshot(date: snapshotDate), at: URL(fileURLWithPath: "/nonexistent-mount"))
  }
  await #expect(throws: DiskSnapshotError.unavailable) {
    try await snapshots.unmount(URL(fileURLWithPath: "/nonexistent-mount"))
  }
  await #expect(throws: DiskSnapshotError.unavailable) {
    try await snapshots.delete(DiskSnapshot(date: snapshotDate))
  }
  await #expect(throws: DiskSnapshotError.unavailable) {
    _ = try await snapshots.existingSnapshotDates()
  }
  #expect(snapshots.mountedSnapshotName(at: URL(fileURLWithPath: "/")) == nil)
}

@Test(
  "snapshot date validation",
  arguments: [
    ("2026-11-23-112124", true),
    ("/", false),
    ("2026-11-23", false),
    ("2026-11-23-11212", false),
    ("2026-11-23-112124x", false),
    ("x2026-11-23-112124", false),
    ("--all", false),
    ("", false),
  ])
func snapshotDateValidation(date: String, expected: Bool) {
  #expect(DiskSnapshot.isValidDate(date) == expected)
}

@Test func snapshotDecodingAndRoundTrip() throws {
  let json = Data(#"{"date":"2026-11-23-112124"}"#.utf8)
  let snapshot = try JSONDecoder().decode(DiskSnapshot.self, from: json)
  #expect(snapshot == DiskSnapshot(date: snapshotDate))
  let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
  #expect(encoded == #"{"date":"2026-11-23-112124"}"#)
}

@Test func decodingInvalidDateThrowsDataCorrupted() throws {
  let json = Data(#"{"date":"/"}"#.utf8)
  do {
    _ = try JSONDecoder().decode(DiskSnapshot.self, from: json)
    Issue.record("decoding an invalid date should have thrown")
  } catch let error as DecodingError {
    guard case .dataCorrupted(let context) = error else {
      Issue.record("expected dataCorrupted, got \(error)")
      return
    }
    #expect(context.codingPath.map(\.stringValue) == ["date"])
    #expect(context.debugDescription == "invalid snapshot date")
  }
}

@Test func mountUsesPrivatePermissions() async throws {
  let (base, mountPoint) = freshMountPoint()
  defer { try? FileManager.default.removeItem(at: base) }
  let (snapshots, _, _, _) = makeSnapshots()
  try await snapshots.mount(DiskSnapshot(date: snapshotDate), at: mountPoint)
  #expect(mode(of: mountPoint.path) == 0o700)
  #expect(mode(of: base.path) == 0o700)
}

@Test func createTimesOutAgainstSlowCommand() async throws {
  let timeout = Duration.milliseconds(100)
  let snapshots = TimeMachineSnapshots(
    tmutil: HangingRunner(),
    mountAPFS: ScriptedRunner(script: [result()]),
    umount: ScriptedRunner(script: [result()]),
    timeout: timeout
  )
  let start = ContinuousClock.now
  await #expect(throws: DiskSnapshotError.createFailed("timed out after \(timeout.components.seconds) s")) {
    _ = try await snapshots.create()
  }
  #expect(start.duration(to: .now) < .seconds(10))
}

@Test func timeoutDoesNotWaitForUncancellableCommand() async throws {
  let gate = Gate()
  defer { gate.signal() }
  let timeout = Duration.milliseconds(100)
  let snapshots = TimeMachineSnapshots(
    tmutil: HangingRunner(gate: gate),
    mountAPFS: ScriptedRunner(script: [result()]),
    umount: ScriptedRunner(script: [result()]),
    timeout: timeout
  )
  let start = ContinuousClock.now
  await #expect(throws: DiskSnapshotError.createFailed("timed out after \(timeout.components.seconds) s")) {
    _ = try await snapshots.create()
  }
  #expect(start.duration(to: .now) < .seconds(10))
}

@Test func callerCancellationWhileCommandRunsThrowsPromptly() async throws {
  let snapshots = TimeMachineSnapshots(
    tmutil: HangingRunner(),
    mountAPFS: ScriptedRunner(script: [result()]),
    umount: ScriptedRunner(script: [result()])
  )
  let start = ContinuousClock.now
  let task = Task {
    try await snapshots.create()
  }
  try await Task.sleep(for: .milliseconds(50))
  task.cancel()
  await #expect(throws: CancellationError.self) {
    _ = try await task.value
  }
  #expect(start.duration(to: .now) < .seconds(10))
}

@Test func mountedSnapshotNameForRootMatchesStatfs() throws {
  var status = statfs()
  try #require(statfs("/", &status) == 0)
  let source = mountSource(of: status)
  let expected: String?
  if let separator = source.firstIndex(of: "@") {
    let prefix = String(source[source.startIndex..<separator])
    expected = prefix.isEmpty ? nil : prefix
  } else {
    expected = nil
  }
  #expect(TimeMachineSnapshots.live().mountedSnapshotName(at: URL(fileURLWithPath: "/")) == expected)
}

@Test func mountedSnapshotNameIsNilForFreshTempDirectory() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(TimeMachineSnapshots.live().mountedSnapshotName(at: directory) == nil)
}

@Test func mountedSnapshotNameIsNilForSymlinkToRoot() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let link = directory.appendingPathComponent("root")
  try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/")
  #expect(TimeMachineSnapshots.live().mountedSnapshotName(at: link) == nil)
}

@Test func mountedSnapshotNameIsNilForMissingPath() {
  let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
  #expect(TimeMachineSnapshots.live().mountedSnapshotName(at: missing) == nil)
}

@Test(
  "live disk snapshot cycle",
  .enabled(if: ProcessInfo.processInfo.environment["FUTO_BACKUPS_DISK_SNAPSHOT_TEST"] == "1"))
func liveDiskSnapshotCycle() async throws {
  let snapshots = TimeMachineSnapshots.live()
  let (base, mountPoint) = freshMountPoint()
  defer { try? FileManager.default.removeItem(at: base) }
  let snapshot = try await snapshots.create()
  do {
    try await snapshots.mount(snapshot, at: mountPoint)
    #expect(snapshots.mountedSnapshotName(at: mountPoint) == snapshot.name)
    #expect(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("Users").path))
    try await snapshots.unmount(mountPoint)
    #expect(snapshots.mountedSnapshotName(at: mountPoint) == nil)
  } catch {
    try? await snapshots.unmount(mountPoint)
    try? await snapshots.delete(snapshot)
    throw error
  }
  try await snapshots.delete(snapshot)
}
