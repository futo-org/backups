import Darwin
import Foundation

public protocol ResticProxyHandle: Sendable {
  var address: String { get }
  func setThrottle(_ throttle: Throttle) throws
  func stop() async
}

public protocol ResticProxyLaunching: Sendable {
  func start(apiRoot: URL, throttle: Throttle) async throws -> any ResticProxyHandle
}

public enum ResticProxyError: Error, Equatable, Sendable {
  case spawnFailed(Int32)
  case notReady(String)
}

public struct ResticProxyLauncher: ResticProxyLaunching {
  private let executable: URL
  private let readyTimeout: Duration

  public init(executable: URL, readyTimeout: Duration = .seconds(10)) {
    self.executable = executable
    self.readyTimeout = readyTimeout
  }

  public func start(apiRoot: URL, throttle: Throttle) async throws -> any ResticProxyHandle {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw ResticProxyError.spawnFailed(errno)
    }
    let parentDescriptor = descriptors[0]
    let childDescriptor = descriptors[1]

    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    defer { posix_spawn_file_actions_destroy(&fileActions) }
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    _ = "/dev/null".withCString { path in
      posix_spawn_file_actions_addopen(&fileActions, 0, path, O_RDONLY, 0)
    }
    posix_spawn_file_actions_addinherit_np(&fileActions, 1)
    posix_spawn_file_actions_addinherit_np(&fileActions, 2)
    posix_spawn_file_actions_adddup2(&fileActions, childDescriptor, 3)

    let environment = [
      "RESTIC_PROXY_API_URL=\(apiURL(apiRoot))",
      "RESTIC_PROXY_HOST=127.0.0.1",
      "RESTIC_PROXY_PORT=0",
      "RESTIC_PROXY_READY_FD=3",
      "RESTIC_PROXY_THROTTLE_BYTES_PER_SEC=\(throttle.bytesPerSec)",
      "RESTIC_PROXY_THROTTLE_QUIET_HOURS=\(throttle.quietHours)",
      "LOG_FORMAT=json",
      "LOG_LEVEL=info",
      "HOME=\(NSHomeDirectory())",
      "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
    ]

    var pid: pid_t = 0
    let spawnResult = executable.path.withCString { path -> Int32 in
      withCStringArray([executable.path]) { argv in
        withCStringArray(environment) { envp in
          posix_spawn(&pid, path, &fileActions, &attributes, argv, envp)
        }
      }
    }
    close(childDescriptor)
    if spawnResult != 0 {
      close(parentDescriptor)
      throw ResticProxyError.spawnFailed(Int32(spawnResult))
    }

    let ready = await Task.detached {
      Self.readReadyLine(descriptor: parentDescriptor, timeout: readyTimeout)
    }.value
    let address: String
    switch ready {
    case .failure(let error):
      _ = kill(pid, SIGKILL)
      _ = waitpid(pid, nil, 0)
      close(parentDescriptor)
      throw error
    case .success(let line):
      guard let data = line.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(ReadyLine.self, from: data)
      else {
        _ = kill(pid, SIGKILL)
        _ = waitpid(pid, nil, 0)
        close(parentDescriptor)
        throw ResticProxyError.notReady("invalid ready line")
      }
      address = decoded.address
    }
    return ProxyHandle(pid: pid, descriptor: parentDescriptor, address: address)
  }

  private func apiURL(_ apiRoot: URL) -> String {
    var text = apiRoot.absoluteString
    while text.hasSuffix("/") {
      text.removeLast()
    }
    return text
  }

  private static func readReadyLine(descriptor: Int32, timeout: Duration) -> Result<String, ResticProxyError> {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    var bytes: [UInt8] = []
    while true {
      let remaining = deadline - clock.now
      if remaining.components.seconds < 0 {
        return .failure(.notReady("timeout"))
      }
      let milliseconds =
        UInt64(remaining.components.seconds) * 1000
        + UInt64(remaining.components.attoseconds / 1_000_000_000_000_000)
      var pollEntry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let readyCount = poll(&pollEntry, 1, Int32(min(milliseconds, UInt64(Int32.max))))
      if readyCount == 0 {
        return .failure(.notReady("timeout"))
      }
      if readyCount < 0 {
        if errno == EINTR { continue }
        return .failure(.notReady("exited before ready"))
      }
      var byte: UInt8 = 0
      let readCount = read(descriptor, &byte, 1)
      if readCount == 0 {
        return .failure(.notReady("exited before ready"))
      }
      if readCount < 0 {
        if errno == EINTR { continue }
        return .failure(.notReady("exited before ready"))
      }
      if byte == 0x0A {
        return .success(String(decoding: bytes, as: UTF8.self))
      }
      bytes.append(byte)
    }
  }
}

public func resticProxyRepositoryURL(address: String, repositoryId: String, accessToken: String) -> String {
  "rest:http://\(repositoryId):\(accessToken)@\(address)"
}

final class ProxyHandle: ResticProxyHandle, @unchecked Sendable {
  private let lock = NSLock()
  private let processIdentifier: pid_t
  private var descriptor: Int32?
  private var reapTask: Task<Void, Never>?
  let address: String

  init(pid: pid_t, descriptor: Int32, address: String) {
    self.processIdentifier = pid
    self.descriptor = descriptor
    self.address = address
  }

  func setThrottle(_ throttle: Throttle) throws {
    let control = ThrottleControl(
      throttle: ThrottleControl.Payload(
        bytesPerSec: throttle.bytesPerSec,
        quietHours: throttle.quietHours))
    var data = try JSONEncoder().encode(control)
    data.append(0x0A)
    lock.lock()
    defer { lock.unlock() }
    guard let descriptor else { throw posixError(EBADF) }
    try Self.writeAll(descriptor: descriptor, data: data)
  }

  func stop() async {
    guard let descriptor = claimDescriptor() else {
      let task = takeReapTask()
      if let task { await task.value }
      return
    }
    _ = kill(processIdentifier, SIGTERM)
    close(descriptor)
    let identifier = processIdentifier
    let task = Task.detached { _ = waitpid(identifier, nil, 0) }
    storeReapTask(task)
    await task.value
  }

  private func claimDescriptor() -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    let descriptor = self.descriptor
    self.descriptor = nil
    return descriptor
  }

  private func takeReapTask() -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    return reapTask
  }

  private func storeReapTask(_ task: Task<Void, Never>) {
    lock.lock()
    defer { lock.unlock() }
    reapTask = task
  }

  private static func writeAll(descriptor: Int32, data: Data) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < data.count {
        let written = write(descriptor, buffer.baseAddress?.advanced(by: offset), data.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw posixError(errno)
        }
        offset += written
      }
    }
  }
}

private func posixError(_ code: Int32) -> POSIXError {
  POSIXError(POSIXError.Code(rawValue: code) ?? .EIO)
}

private func withCStringArray<Result>(
  _ strings: [String],
  _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) rethrows -> Result {
  var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
  pointers.append(nil)
  defer {
    for pointer in pointers {
      free(pointer)
    }
  }
  return try pointers.withUnsafeMutableBufferPointer { buffer in
    try body(buffer.baseAddress!)
  }
}

private struct ReadyLine: Decodable {
  var address: String
}

private struct ThrottleControl: Encodable {
  struct Payload: Encodable {
    var bytesPerSec: Int
    var quietHours: String
  }

  var type = "throttle"
  var throttle: Payload
}
