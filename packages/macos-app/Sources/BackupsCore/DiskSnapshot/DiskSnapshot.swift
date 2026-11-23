import Darwin
import Foundation

public struct DiskSnapshot: Codable, Equatable, Sendable {
  public var date: String

  public init(date: String) {
    self.date = date
  }

  public var name: String { "com.apple.TimeMachine.\(date).local" }
}

public enum DiskSnapshotError: Error, Equatable, Sendable, CustomStringConvertible {
  case unavailable
  case noFullDiskAccess
  case createFailed(String)
  case mountFailed(String)
  case unmountFailed(String)
  case deleteFailed(String)

  public var description: String {
    switch self {
    case .unavailable:
      "Disk snapshots are unavailable."
    case .noFullDiskAccess:
      "Backing up from a disk snapshot needs Full Disk Access. Grant it in System Settings, or turn off disk snapshots in Settings."
    case .createFailed(let detail):
      "Could not create a disk snapshot: \(detail)"
    case .mountFailed(let detail):
      "Could not open the disk snapshot: \(detail)"
    case .unmountFailed(let detail):
      "Could not close the disk snapshot: \(detail)"
    case .deleteFailed(let detail):
      "Could not delete the disk snapshot: \(detail)"
    }
  }
}

public protocol DiskSnapshotting: Sendable {
  func create() async throws -> DiskSnapshot
  func mount(_ snapshot: DiskSnapshot, at mountPoint: URL) async throws
  func unmount(_ mountPoint: URL) async throws
  func delete(_ snapshot: DiskSnapshot) async throws
  func isMounted(_ mountPoint: URL) -> Bool
}

public struct UnavailableDiskSnapshots: DiskSnapshotting {
  public init() {}

  public func create() async throws -> DiskSnapshot {
    throw DiskSnapshotError.unavailable
  }

  public func mount(_ snapshot: DiskSnapshot, at mountPoint: URL) async throws {
    throw DiskSnapshotError.unavailable
  }

  public func unmount(_ mountPoint: URL) async throws {
    throw DiskSnapshotError.unavailable
  }

  public func delete(_ snapshot: DiskSnapshot) async throws {
    throw DiskSnapshotError.unavailable
  }

  public func isMounted(_ mountPoint: URL) -> Bool {
    false
  }
}

public struct TimeMachineSnapshots: DiskSnapshotting {
  private let tmutilRunner: any ResticExecuting
  private let mountAPFSRunner: any ResticExecuting
  private let umountRunner: any ResticExecuting

  public init(tmutil: any ResticExecuting, mountAPFS: any ResticExecuting, umount: any ResticExecuting) {
    self.tmutilRunner = tmutil
    self.mountAPFSRunner = mountAPFS
    self.umountRunner = umount
  }

  public static func live() -> TimeMachineSnapshots {
    TimeMachineSnapshots(
      tmutil: ResticRunner(executable: URL(fileURLWithPath: "/usr/bin/tmutil")),
      mountAPFS: ResticRunner(executable: URL(fileURLWithPath: "/sbin/mount_apfs")),
      umount: ResticRunner(executable: URL(fileURLWithPath: "/sbin/umount"))
    )
  }

  public func create() async throws -> DiskSnapshot {
    let result = try await tmutilRunner.run(invocation(["localsnapshot"]), onLine: { _ in })
    let output = String(decoding: result.stdout, as: UTF8.self)
    let datePattern = #/Created local snapshot with date: (\d{4}-\d{2}-\d{2}-\d{6})/#
    if result.exitCode == 0, let match = output.firstMatch(of: datePattern) {
      return DiskSnapshot(date: String(match.output.1))
    }
    throw DiskSnapshotError.createFailed(failureDetail(result))
  }

  public func mount(_ snapshot: DiskSnapshot, at mountPoint: URL) async throws {
    do {
      try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
    } catch {
      throw DiskSnapshotError.mountFailed(String(describing: error))
    }
    let result = try await mountAPFSRunner.run(
      invocation(["-o", "ro,nobrowse", "-s", snapshot.name, "/System/Volumes/Data", mountPoint.path]),
      onLine: { _ in }
    )
    guard result.exitCode != 0 else { return }
    let detail = failureDetail(result)
    if detail.contains("Operation not permitted") {
      throw DiskSnapshotError.noFullDiskAccess
    }
    throw DiskSnapshotError.mountFailed(detail)
  }

  public func unmount(_ mountPoint: URL) async throws {
    let first = try await umountRunner.run(invocation([mountPoint.path]), onLine: { _ in })
    if first.exitCode == 0 {
      return
    }
    let second = try await umountRunner.run(invocation(["-f", mountPoint.path]), onLine: { _ in })
    if second.exitCode == 0 {
      return
    }
    throw DiskSnapshotError.unmountFailed(failureDetail(second))
  }

  public func delete(_ snapshot: DiskSnapshot) async throws {
    let result = try await tmutilRunner.run(
      invocation(["deletelocalsnapshots", snapshot.date]),
      onLine: { _ in }
    )
    if result.exitCode != 0 {
      throw DiskSnapshotError.deleteFailed(failureDetail(result))
    }
  }

  public func isMounted(_ mountPoint: URL) -> Bool {
    guard let resolved = realpath(mountPoint.path, nil) else { return false }
    defer { free(resolved) }
    let realPath = String(cString: resolved)
    var status = statfs()
    guard statfs(realPath, &status) == 0 else { return false }
    return mountName(of: status) == realPath
  }

  private static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  private func invocation(_ arguments: [String]) -> ResticInvocation {
    ResticInvocation(arguments: arguments, environment: ["PATH": Self.systemPath])
  }
}

private func failureDetail(_ result: ResticResult) -> String {
  let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
  if !stderr.isEmpty {
    return stderr
  }
  let stdout = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  if !stdout.isEmpty {
    return stdout
  }
  return "exit code \(result.exitCode)"
}

private func mountName(of status: statfs) -> String {
  withUnsafePointer(to: status.f_mntonname) { tuple in
    tuple.withMemoryRebound(to: CChar.self, capacity: 1024) { bytes in
      String(cString: bytes)
    }
  }
}
