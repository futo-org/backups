import Darwin
import Foundation
import Testing

@testable import BackupsCore

private final class LineCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ line: String) {
    lock.lock()
    storage.append(line)
    lock.unlock()
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private func shInvocation(_ script: String, environment: [String: String] = ["PATH": "/usr/bin:/bin"])
  -> ResticInvocation
{
  ResticInvocation(arguments: ["-c", script], environment: environment)
}

private let sh = URL(fileURLWithPath: "/bin/sh")

@Test func stdoutLinesStderrAndExitCode() async throws {
  let sink = LineCollector()
  let runner = ResticRunner(executable: sh)
  let result = try await runner.run(shInvocation("printf 'a\\nb\\nc\\n'; echo oops >&2; exit 3")) { line in
    sink.append(line)
  }
  #expect(result.exitCode == 3)
  #expect(result.stderr == "oops\n")
  #expect(String(decoding: result.stdout, as: UTF8.self) == "a\nb\nc\n")
  #expect(sink.snapshot() == ["a", "b", "c"])
}

@Test func finalLineWithoutNewlineIsDelivered() async throws {
  let sink = LineCollector()
  let runner = ResticRunner(executable: sh)
  let result = try await runner.run(shInvocation("printf 'x\\ny'")) { line in
    sink.append(line)
  }
  #expect(result.exitCode == 0)
  #expect(sink.snapshot() == ["x", "y"])
  #expect(String(decoding: result.stdout, as: UTF8.self) == "x\ny\n")
}

@Test func environmentIsReplacedNotInherited() async throws {
  setenv("FUTO_BACKUPS_LEAK_CHECK", "leaked", 1)
  let sink = LineCollector()
  let runner = ResticRunner(executable: sh)
  let result = try await runner.run(
    shInvocation(
      #"printf 'FOO=%s\nLEAK=[%s]\n' "$FOO" "$FUTO_BACKUPS_LEAK_CHECK""#,
      environment: ["FOO": "bar", "PATH": "/usr/bin:/bin"])
  ) { line in
    sink.append(line)
  }
  #expect(result.exitCode == 0)
  #expect(sink.snapshot() == ["FOO=bar", "LEAK=[]"])
}

@Test func launchFailureThrows() async {
  let runner = ResticRunner(executable: URL(fileURLWithPath: "/nonexistent/restic-binary"))
  await #expect(throws: (any Error).self) {
    _ = try await runner.run(shInvocation("true"), onLine: { _ in })
  }
}

@Test func cancellationThrowsCancellationError() async throws {
  let runner = ResticRunner(executable: sh)
  let task = Task {
    try await runner.run(shInvocation("sleep 30"), onLine: { _ in })
  }
  try await Task.sleep(for: .milliseconds(300))
  task.cancel()
  let start = ContinuousClock.now
  var thrown: (any Error)?
  do {
    _ = try await task.value
  } catch {
    thrown = error
  }
  let elapsed = ContinuousClock.now - start
  #expect(thrown is CancellationError)
  #expect(elapsed < .seconds(5), "elapsed \(elapsed.components.seconds)s")
}
