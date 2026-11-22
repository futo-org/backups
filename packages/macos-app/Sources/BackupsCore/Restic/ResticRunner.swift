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
    let outputHandle = outputPipe.fileHandleForReading
    let errorHandle = errorPipe.fileHandleForReading
    let outputDescriptor = outputHandle.fileDescriptor
    let errorDescriptor = errorHandle.fileDescriptor

    return try await withTaskCancellationHandler {
      let result = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<ResticResult, Error>) in
        let outputTask = Task.detached(priority: .utility) {
          PipeReader.readLines(descriptor: outputDescriptor, onLine: onLine)
        }
        let errorTask = Task.detached(priority: .utility) {
          String(decoding: PipeReader.readAll(descriptor: errorDescriptor), as: UTF8.self)
        }
        process.value.terminationHandler = { _ in
          Task.detached(priority: .utility) {
            let stdoutData = await outputTask.value
            let stderrText = await errorTask.value
            continuation.resume(
              returning: ResticResult(
                exitCode: process.value.terminationStatus,
                stdout: stdoutData,
                stderr: stderrText))
          }
        }
        do {
          if Task.isCancelled { throw CancellationError() }
          try process.value.run()
        } catch {
          try? outputHandle.close()
          try? errorHandle.close()
          continuation.resume(throwing: error)
        }
      }
      if Task.isCancelled { throw CancellationError() }
      return result
    } onCancel: {
      if process.value.isRunning {
        process.value.terminate()
      }
    }
  }
}

private final class ProcessBox: @unchecked Sendable {
  let value = Process()
}

private enum PipeReader {
  static func readLines(descriptor: Int32, onLine: @escaping @Sendable (String) -> Void) -> Data {
    var pending: [UInt8] = []
    var lines: [String] = []
    consume(descriptor: descriptor) { chunk in
      pending.append(contentsOf: chunk)
      while let index = pending.firstIndex(of: 0x0A) {
        let line = String(decoding: Data(pending[..<index]), as: UTF8.self)
        pending.removeSubrange(pending.startIndex...index)
        lines.append(line)
        onLine(line)
      }
    }
    if !pending.isEmpty {
      let line = String(decoding: pending, as: UTF8.self)
      lines.append(line)
      onLine(line)
    }
    guard !lines.isEmpty else { return Data() }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
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
