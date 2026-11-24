import Darwin
import Foundation

public struct DiskSnapshot: Codable, Equatable, Sendable {
  public var date: String

  public init(date: String) {
    self.date = date
  }

  public var name: String { "com.apple.TimeMachine.\(date).local" }

  public static func isValidDate(_ date: String) -> Bool {
    date.wholeMatch(of: /^\d{4}-\d{2}-\d{2}-\d{6}$/) != nil
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let date = try container.decode(String.self, forKey: .date)
    guard Self.isValidDate(date) else {
      throw DecodingError.dataCorruptedError(
        forKey: .date, in: container, debugDescription: "invalid snapshot date")
    }
    self.date = date
  }

  enum CodingKeys: String, CodingKey {
    case date
  }
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

  public var telemetryCode: String {
    switch self {
    case .unavailable:
      "unavailable"
    case .noFullDiskAccess:
      "no-full-disk-access"
    case .createFailed:
      "create-failed"
    case .mountFailed:
      "mount-failed"
    case .unmountFailed:
      "unmount-failed"
    case .deleteFailed:
      "delete-failed"
    }
  }
}

public protocol DiskSnapshotting: Sendable {
  func create() async throws -> DiskSnapshot
  func mount(_ snapshot: DiskSnapshot, at mountPoint: URL) async throws
  func unmount(_ mountPoint: URL) async throws
  func delete(_ snapshot: DiskSnapshot) async throws
  func mountedSnapshotName(at mountPoint: URL) -> String?
  func existingSnapshotDates() async throws -> Set<String>
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

  public func mountedSnapshotName(at mountPoint: URL) -> String? {
    nil
  }

  public func existingSnapshotDates() async throws -> Set<String> {
    throw DiskSnapshotError.unavailable
  }
}

public struct TimeMachineSnapshots: DiskSnapshotting {
  private let tmutilRunner: any ResticExecuting
  private let mountAPFSRunner: any ResticExecuting
  private let umountRunner: any ResticExecuting
  private let timeout: Duration

  public init(
    tmutil: any ResticExecuting,
    mountAPFS: any ResticExecuting,
    umount: any ResticExecuting,
    timeout: Duration = .seconds(120)
  ) {
    self.tmutilRunner = tmutil
    self.mountAPFSRunner = mountAPFS
    self.umountRunner = umount
    self.timeout = timeout
  }

  public static func live() -> TimeMachineSnapshots {
    TimeMachineSnapshots(
      tmutil: ResticRunner(executable: URL(fileURLWithPath: "/usr/bin/tmutil")),
      mountAPFS: ResticRunner(executable: URL(fileURLWithPath: "/sbin/mount_apfs")),
      umount: ResticRunner(executable: URL(fileURLWithPath: "/sbin/umount"))
    )
  }

  public func create() async throws -> DiskSnapshot {
    let result: ResticResult
    do {
      result = try await run(tmutilRunner, ["localsnapshot"])
    } catch is SnapshotCommandTimedOut {
      throw DiskSnapshotError.createFailed(timeoutDetail)
    }
    let output = String(decoding: result.stdout, as: UTF8.self)
    let datePattern = #/Created local snapshot with date: (\d{4}-\d{2}-\d{2}-\d{6})/#
    if result.exitCode == 0, let match = output.firstMatch(of: datePattern) {
      return DiskSnapshot(date: String(match.output.1))
    }
    throw DiskSnapshotError.createFailed(failureDetail(result))
  }

  public func mount(_ snapshot: DiskSnapshot, at mountPoint: URL) async throws {
    do {
      try FileManager.default.createDirectory(
        at: mountPoint,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: mountPoint.deletingLastPathComponent().path
      )
    } catch {
      throw DiskSnapshotError.mountFailed(String(describing: error))
    }
    let result: ResticResult
    do {
      result = try await run(
        mountAPFSRunner,
        ["-o", "ro,nobrowse", "-s", snapshot.name, "/System/Volumes/Data", mountPoint.path])
    } catch is SnapshotCommandTimedOut {
      throw DiskSnapshotError.mountFailed(timeoutDetail)
    }
    guard result.exitCode != 0 else { return }
    let detail = failureDetail(result)
    if detail.contains("Operation not permitted") {
      throw DiskSnapshotError.noFullDiskAccess
    }
    throw DiskSnapshotError.mountFailed(detail)
  }

  public func unmount(_ mountPoint: URL) async throws {
    let first: ResticResult
    do {
      first = try await run(umountRunner, [mountPoint.path])
    } catch is SnapshotCommandTimedOut {
      throw DiskSnapshotError.unmountFailed(timeoutDetail)
    }
    if first.exitCode == 0 {
      return
    }
    let second: ResticResult
    do {
      second = try await run(umountRunner, ["-f", mountPoint.path])
    } catch is SnapshotCommandTimedOut {
      throw DiskSnapshotError.unmountFailed(timeoutDetail)
    }
    if second.exitCode == 0 {
      return
    }
    throw DiskSnapshotError.unmountFailed(failureDetail(second))
  }

  public func delete(_ snapshot: DiskSnapshot) async throws {
    guard DiskSnapshot.isValidDate(snapshot.date) else {
      throw DiskSnapshotError.deleteFailed("invalid snapshot date")
    }
    let result: ResticResult
    do {
      result = try await run(tmutilRunner, ["deletelocalsnapshots", snapshot.date])
    } catch is SnapshotCommandTimedOut {
      throw DiskSnapshotError.deleteFailed(timeoutDetail)
    }
    if result.exitCode != 0 {
      throw DiskSnapshotError.deleteFailed(failureDetail(result))
    }
  }

  public func mountedSnapshotName(at mountPoint: URL) -> String? {
    var info = stat()
    guard lstat(mountPoint.path, &info) == 0 else { return nil }
    if info.st_mode & S_IFMT == S_IFLNK { return nil }
    guard let resolved = realpath(mountPoint.path, nil) else { return nil }
    defer { free(resolved) }
    let realPath = String(cString: resolved)
    var status = statfs()
    guard statfs(realPath, &status) == 0 else { return nil }
    guard mountName(of: status) == realPath else { return nil }
    let source = mountSource(of: status)
    guard let separator = source.firstIndex(of: "@") else { return nil }
    let name = String(source[source.startIndex..<separator])
    return name.isEmpty ? nil : name
  }

  public func existingSnapshotDates() async throws -> Set<String> {
    let result: ResticResult
    do {
      result = try await run(tmutilRunner, ["listlocalsnapshotdates", "/"])
    } catch is SnapshotCommandTimedOut {
      throw DiskSnapshotError.deleteFailed(timeoutDetail)
    }
    guard result.exitCode == 0 else {
      throw DiskSnapshotError.deleteFailed(failureDetail(result))
    }
    let output = String(decoding: result.stdout, as: UTF8.self)
    var dates: Set<String> = []
    for line in output.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if DiskSnapshot.isValidDate(trimmed) {
        dates.insert(trimmed)
      }
    }
    return dates
  }

  private static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

  private var timeoutDetail: String {
    "timed out after \(timeout.components.seconds) s"
  }

  private func run(_ runner: any ResticExecuting, _ arguments: [String]) async throws
    -> ResticResult
  {
    let command = Task {
      try await runner.run(invocation(arguments), onLine: { _ in })
    }
    let timer = Task {
      try await Task.sleep(for: timeout)
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<ResticResult, any Error>) in
        let once = ResumeOnce()
        Task {
          do {
            let result = try await command.value
            if once.claim() {
              continuation.resume(returning: result)
            }
          } catch {
            if once.claim() {
              continuation.resume(throwing: error)
            }
          }
        }
        Task {
          do {
            try await timer.value
            if once.claim() {
              command.cancel()
              continuation.resume(throwing: SnapshotCommandTimedOut())
            }
          } catch {
            if once.claim() {
              continuation.resume(throwing: CancellationError())
            }
          }
        }
      }
    } onCancel: {
      command.cancel()
      timer.cancel()
    }
  }

  private func invocation(_ arguments: [String]) -> ResticInvocation {
    ResticInvocation(arguments: arguments, environment: ["PATH": Self.systemPath])
  }
}

private struct SnapshotCommandTimedOut: Error {}

private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.withLock {
      if claimed {
        return false
      }
      claimed = true
      return true
    }
  }
}

private func failureDetail(_ result: ResticResult) -> String {
  let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
  if !stderr.isEmpty {
    return stderr
  }
  let stdout = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(
    in: .whitespacesAndNewlines)
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

private func mountSource(of status: statfs) -> String {
  withUnsafePointer(to: status.f_mntfromname) { tuple in
    tuple.withMemoryRebound(to: CChar.self, capacity: 1024) { bytes in
      String(cString: bytes)
    }
  }
}
