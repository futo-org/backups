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
  umount: ScriptedRunner = ScriptedRunner(script: [result()])
) -> (TimeMachineSnapshots, ScriptedRunner, ScriptedRunner, ScriptedRunner) {
  (TimeMachineSnapshots(tmutil: tmutil, mountAPFS: mountAPFS, umount: umount), tmutil, mountAPFS, umount)
}

private func freshMountPoint() -> (base: URL, mountPoint: URL) {
  let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  return (base, base.appendingPathComponent("Volume"))
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
  ])
func errorDescriptions(error: DiskSnapshotError, expected: String) {
  #expect(error.description == expected)
}

@Test func unavailableDiskSnapshotsThrowsAndReportsFalse() async {
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
  #expect(!snapshots.isMounted(URL(fileURLWithPath: "/")))
}

@Test func isMountedIsFalseForFreshTempDirectory() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(!TimeMachineSnapshots.live().isMounted(directory))
}

@Test func isMountedIsTrueForRoot() {
  #expect(TimeMachineSnapshots.live().isMounted(URL(fileURLWithPath: "/")))
}

@Test func isMountedIsFalseForMissingPath() {
  #expect(!TimeMachineSnapshots.live().isMounted(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")))
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
    #expect(snapshots.isMounted(mountPoint))
    #expect(FileManager.default.fileExists(atPath: mountPoint.appendingPathComponent("Users").path))
    try await snapshots.unmount(mountPoint)
    #expect(!snapshots.isMounted(mountPoint))
  } catch {
    try? await snapshots.unmount(mountPoint)
    try? await snapshots.delete(snapshot)
    throw error
  }
  try await snapshots.delete(snapshot)
}
