import Darwin
import Foundation

public protocol ResticProxyHandle: Sendable {
  var address: String { get }
  var uploadedBytes: Int64 { get }
  func setThrottle(_ throttle: Throttle) throws
  func networkChanged() throws
  func stop() async
}

extension ResticProxyHandle {
  public func networkChanged() throws {}
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
  private let progressInterval: Duration

  public init(
    executable: URL, readyTimeout: Duration = .seconds(10), progressInterval: Duration = .milliseconds(500)
  ) {
    self.executable = executable
    self.readyTimeout = readyTimeout
    self.progressInterval = progressInterval
  }

  public func start(apiRoot: URL, throttle: Throttle) async throws -> any ResticProxyHandle {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw ResticProxyError.spawnFailed(errno)
    }
    let parentDescriptor = descriptors[0]
    let childDescriptor = descriptors[1]
    var noSigpipe: Int32 = 1
    _ = setsockopt(parentDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

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
      "RESTIC_PROXY_PROGRESS_INTERVAL_MS=\(Int(progressInterval / .milliseconds(1)))",
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

    let ready: Result<String, ResticProxyError> = await withCheckedContinuation {
      (continuation: CheckedContinuation<Result<String, ResticProxyError>, Never>) in
      let thread = Thread {
        continuation.resume(returning: Self.readReadyLine(descriptor: parentDescriptor, timeout: readyTimeout))
      }
      thread.start()
    }
    let address: String
    switch ready {
    case .failure(let error):
      _ = kill(pid, SIGKILL)
      await reapProcess(pid)
      close(parentDescriptor)
      throw error
    case .success(let line):
      guard let data = line.data(using: .utf8),
        let decoded = try? JSONDecoder().decode(ReadyLine.self, from: data)
      else {
        _ = kill(pid, SIGKILL)
        await reapProcess(pid)
        close(parentDescriptor)
        throw ResticProxyError.notReady("invalid ready line")
      }
      address = decoded.address
    }
    let handle = ProxyHandle(pid: pid, descriptor: parentDescriptor, address: address)
    handle.startReadingProgress()
    return handle
  }

  private func apiURL(_ apiRoot: URL) -> String {
    var text = apiRoot.absoluteString
    while text.hasSuffix("/") {
      text.removeLast()
    }
    return text
  }

  static func pollTimeoutMilliseconds(_ remaining: Duration) -> Int32 {
    guard remaining > .zero else { return 0 }
    let seconds = remaining.components.seconds
    if seconds >= Int64(Int32.max) / 1000 {
      return Int32.max
    }
    let milliseconds =
      seconds * 1000 + (remaining.components.attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
    return Int32(min(max(milliseconds, 1), Int64(Int32.max)))
  }

  private static func readReadyLine(descriptor: Int32, timeout: Duration) -> Result<String, ResticProxyError> {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    let flags = fcntl(descriptor, F_GETFL)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    defer {
      _ = fcntl(descriptor, F_SETFL, flags)
    }
    var bytes: [UInt8] = []
    while true {
      let remaining = deadline - clock.now
      if remaining <= .zero {
        return .failure(.notReady("timeout"))
      }
      var pollEntry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let readyCount = poll(&pollEntry, 1, pollTimeoutMilliseconds(remaining))
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
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
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
  private let uploaded = UploadedBytes()
  let address: String

  init(pid: pid_t, descriptor: Int32, address: String) {
    self.processIdentifier = pid
    self.descriptor = descriptor
    self.address = address
  }

  var uploadedBytes: Int64 {
    uploaded.value
  }

  func startReadingProgress() {
    guard let source = lock.withLock({ descriptor }) else { return }
    let reader = dup(source)
    guard reader >= 0 else { return }
    let uploaded = self.uploaded
    let thread = Thread {
      Self.readProgress(descriptor: reader, into: uploaded)
    }
    thread.start()
  }

  private static func readProgress(descriptor: Int32, into uploaded: UploadedBytes) {
    defer { close(descriptor) }
    var lines = ResticProxyMessages()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return }
      if let total = lines.latestUploadedBytes(after: buffer[0..<count]) {
        uploaded.set(total)
      }
    }
  }

  func setThrottle(_ throttle: Throttle) throws {
    try send(
      ThrottleControl(
        throttle: ThrottleControl.Payload(
          bytesPerSec: throttle.bytesPerSec,
          quietHours: throttle.quietHours)))
  }

  func networkChanged() throws {
    try send(NetworkChangedControl())
  }

  private func send(_ control: some Encodable) throws {
    var data = try JSONEncoder().encode(control)
    data.append(0x0A)
    lock.lock()
    guard let source = descriptor else {
      lock.unlock()
      throw posixError(EBADF)
    }
    let target = dup(source)
    lock.unlock()
    guard target >= 0 else {
      throw posixError(errno)
    }
    defer {
      close(target)
    }
    try Self.writeAll(descriptor: target, data: data)
  }

  func stop() async {
    guard let descriptor = claimDescriptor() else {
      let task = takeReapTask()
      if let task { await task.value }
      return
    }
    _ = kill(processIdentifier, SIGTERM)
    _ = shutdown(descriptor, SHUT_RDWR)
    close(descriptor)
    let identifier = processIdentifier
    let task = Task { await reapProcess(identifier) }
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

private func reapProcess(_ identifier: pid_t) async {
  await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
    let thread = Thread {
      _ = waitpid(identifier, nil, 0)
      continuation.resume()
    }
    thread.start()
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

final class UploadedBytes: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Int64 = 0

  var value: Int64 {
    lock.withLock { stored }
  }

  func set(_ value: Int64) {
    lock.withLock { stored = value }
  }
}

struct ResticProxyMessages {
  static let maxLineLength = 64 * 1024

  private struct Message: Decodable {
    var type: String
    var uploadedBytes: Int64?
  }

  private var pending: [UInt8] = []
  private var discarding = false

  mutating func latestUploadedBytes(after bytes: some Collection<UInt8>) -> Int64? {
    var latest: Int64?
    for byte in bytes {
      if byte == 0x0A {
        if !discarding, let total = Self.uploadedBytes(in: pending) {
          latest = total
        }
        pending.removeAll(keepingCapacity: true)
        discarding = false
      } else if pending.count >= Self.maxLineLength {
        pending.removeAll(keepingCapacity: true)
        discarding = true
      } else if !discarding {
        pending.append(byte)
      }
    }
    return latest
  }

  private static func uploadedBytes(in line: [UInt8]) -> Int64? {
    guard let message = try? JSONDecoder().decode(Message.self, from: Data(line)), message.type == "progress"
    else { return nil }
    return message.uploadedBytes
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

private struct NetworkChangedControl: Encodable {
  var type = "network-changed"
}
