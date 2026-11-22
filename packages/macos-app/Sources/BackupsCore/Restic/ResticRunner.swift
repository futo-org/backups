import Darwin
import Foundation

public struct ResticResult: Equatable, Sendable {
  public var exitCode: Int32
  public var stdout: Data
  public var stderr: String
}

public protocol ResticExecuting: Sendable {
  func run(_ invocation: ResticInvocation, onLine: @escaping @Sendable (String) -> Void) async throws -> ResticResult
}

public struct ResticRunner: ResticExecuting {
  private let executable: URL

  public init(executable: URL) {
    self.executable = executable
  }

  public func run(_ invocation: ResticInvocation, onLine: @escaping @Sendable (String) -> Void) async throws
    -> ResticResult
  {
    let process = ProcessBox()
    process.value.executableURL = executable
    process.value.arguments = invocation.arguments
    process.value.environment = invocation.environment
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.value.standardOutput = outputPipe
    process.value.standardError = errorPipe
    let outputReadHandle = outputPipe.fileHandleForReading
    let outputWriteHandle = outputPipe.fileHandleForWriting
    let errorReadHandle = errorPipe.fileHandleForReading
    let errorWriteHandle = errorPipe.fileHandleForWriting
    let outputDescriptor = outputReadHandle.fileDescriptor
    let errorDescriptor = errorReadHandle.fileDescriptor
    let state = LaunchState()
    let join = RunnerJoin()

    return try await withTaskCancellationHandler {
      let result = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<ResticResult, Error>) in
        join.attach(continuation)
        if state.finishIfCancelled(taskCancelled: Task.isCancelled) {
          join.detach()?.resume(throwing: CancellationError())
          closeHandles(outputReadHandle, outputWriteHandle, errorReadHandle, errorWriteHandle)
          return
        }
        process.value.terminationHandler = { finished in
          let status = finished.terminationStatus
          finished.terminationHandler = nil
          join.deliver(exitCode: status)
        }
        do {
          try process.value.run()
        } catch {
          process.value.terminationHandler = nil
          _ = state.markFinished()
          join.detach()?.resume(throwing: error)
          closeHandles(outputReadHandle, outputWriteHandle, errorReadHandle, errorWriteHandle)
          return
        }
        if state.markRunning() {
          process.value.terminate()
        }
        let outputThread = Thread {
          join.deliver(stdout: PipeReader.readLines(descriptor: outputDescriptor, onLine: onLine))
        }
        outputThread.start()
        let errorThread = Thread {
          join.deliver(stderr: String(decoding: PipeReader.readAll(descriptor: errorDescriptor), as: UTF8.self))
        }
        errorThread.start()
      }
      let cancelled = state.markFinished()
      if cancelled || Task.isCancelled { throw CancellationError() }
      return result
    } onCancel: {
      if state.requestCancel() {
        process.value.terminate()
      }
    }
  }
}

private func closeHandles(_ handles: FileHandle...) {
  for handle in handles {
    try? handle.close()
  }
}

private final class ProcessBox: @unchecked Sendable {
  let value = Process()
}

private final class LaunchState: @unchecked Sendable {
  enum Phase {
    case notStarted
    case running
    case finished
  }

  private let lock = NSLock()
  private var phase = Phase.notStarted
  private var cancelRequested = false

  func finishIfCancelled(taskCancelled: Bool) -> Bool {
    lock.lock()
    let cancelled = cancelRequested || taskCancelled
    if cancelled {
      phase = .finished
    }
    lock.unlock()
    return cancelled
  }

  func markRunning() -> Bool {
    lock.lock()
    phase = .running
    let cancelRequested = self.cancelRequested
    lock.unlock()
    return cancelRequested
  }

  func markFinished() -> Bool {
    lock.lock()
    phase = .finished
    let cancelRequested = self.cancelRequested
    lock.unlock()
    return cancelRequested
  }

  func requestCancel() -> Bool {
    lock.lock()
    cancelRequested = true
    let shouldTerminate = phase == .running
    lock.unlock()
    return shouldTerminate
  }
}

private final class RunnerJoin: @unchecked Sendable {
  private let lock = NSLock()
  private var exitCode: Int32?
  private var stdoutData: Data?
  private var stderrText: String?
  private var continuation: CheckedContinuation<ResticResult, Error>?

  func attach(_ continuation: CheckedContinuation<ResticResult, Error>) {
    lock.lock()
    self.continuation = continuation
    let result = resultLocked()
    if result != nil {
      self.continuation = nil
    }
    lock.unlock()
    if let result {
      continuation.resume(returning: result)
    }
  }

  func detach() -> CheckedContinuation<ResticResult, Error>? {
    lock.lock()
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    return continuation
  }

  func deliver(exitCode: Int32) {
    settle { self.exitCode = exitCode }
  }

  func deliver(stdout: Data) {
    settle { self.stdoutData = stdout }
  }

  func deliver(stderr: String) {
    settle { self.stderrText = stderr }
  }

  private func settle(_ record: () -> Void) {
    var continuationToResume: CheckedContinuation<ResticResult, Error>?
    var resumedResult: ResticResult?
    lock.lock()
    record()
    let result = resultLocked()
    if result != nil {
      continuationToResume = continuation
      continuation = nil
      resumedResult = result
    }
    lock.unlock()
    if let continuationToResume, let resumedResult {
      continuationToResume.resume(returning: resumedResult)
    }
  }

  private func resultLocked() -> ResticResult? {
    guard let exitCode, let stdoutData, let stderrText else { return nil }
    return ResticResult(exitCode: exitCode, stdout: stdoutData, stderr: stderrText)
  }
}

private enum PipeReader {
  static func readLines(descriptor: Int32, onLine: @escaping @Sendable (String) -> Void) -> Data {
    var raw = Data()
    var pending: [UInt8] = []
    var searched = 0
    consume(descriptor: descriptor) { chunk in
      raw.append(contentsOf: chunk)
      pending.append(contentsOf: chunk)
      while pending.count > searched, let index = pending[searched...].firstIndex(of: 0x0A) {
        let line = String(decoding: Data(pending[..<index]), as: UTF8.self)
        pending.removeSubrange(pending.startIndex...index)
        searched = 0
        onLine(line)
      }
      searched = pending.count
    }
    if !pending.isEmpty {
      onLine(String(decoding: pending, as: UTF8.self))
    }
    return raw
  }

  static func readAll(descriptor: Int32) -> Data {
    var received = Data()
    consume(descriptor: descriptor) { chunk in
      received.append(contentsOf: chunk)
    }
    return received
  }

  private static func consume(descriptor: Int32, handle: ([UInt8]) -> Void) {
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count > 0 {
        handle(Array(buffer[0..<count]))
      } else if count < 0 && errno == EINTR {
        continue
      } else {
        return
      }
    }
  }
}
