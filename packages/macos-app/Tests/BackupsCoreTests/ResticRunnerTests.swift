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

@Test func unretainedStdoutStillDeliversLinesButKeepsNoCopy() async throws {
  let sink = LineCollector()
  let runner = ResticRunner(executable: sh)
  var invocation = shInvocation("printf 'a\\nb\\nc'; echo oops >&2; exit 3")
  invocation.retainsStdout = false
  let result = try await runner.run(invocation) { line in
    sink.append(line)
  }
  #expect(result.exitCode == 3)
  #expect(result.stderr == "oops\n")
  #expect(result.stdout.isEmpty)
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
  #expect(String(decoding: result.stdout, as: UTF8.self) == "x\ny")
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

private func openDescriptorCount() throws -> Int {
  try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

private let bigPipeScript = #"head -c 4194304 /dev/zero | tr "\0" a >&2; head -c 4194304 /dev/zero | tr "\0" b"#

@Test func failedLaunchesDoNotLeakDescriptors() async throws {
  let runner = ResticRunner(executable: URL(fileURLWithPath: "/nonexistent/restic-binary"))
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  var delta = 0
  var stable = false
  while ContinuousClock.now < deadline {
    let before = try openDescriptorCount()
    for _ in 0..<20 {
      do {
        _ = try await runner.run(shInvocation("true"), onLine: { _ in })
        Issue.record("launch unexpectedly succeeded")
      } catch {}
    }
    delta = try openDescriptorCount() - before
    if delta == 0 {
      stable = true
      break
    }
    try await Task.sleep(for: .milliseconds(200))
  }
  #expect(stable, "descriptor delta \(delta) persisted across 20 failed launches")
}

@Test func largeStdoutAndStderrComplete() async throws {
  let runner = ResticRunner(executable: sh)
  let start = ContinuousClock.now
  let result = try await runner.run(shInvocation(bigPipeScript), onLine: { _ in })
  let elapsed = ContinuousClock.now - start
  #expect(result.exitCode == 0)
  #expect(result.stderr.count == 4_194_304)
  #expect(result.stdout.count == 4_194_304)
  #expect(elapsed < .seconds(20), "elapsed \(elapsed.components.seconds)s")
}

@Test func fourConcurrentLargePipeRuns() async throws {
  let runner = ResticRunner(executable: sh)
  let start = ContinuousClock.now
  let results = try await withThrowingTaskGroup(of: ResticResult.self) { group in
    for _ in 0..<4 {
      group.addTask {
        try await runner.run(shInvocation(bigPipeScript), onLine: { _ in })
      }
    }
    var collected: [ResticResult] = []
    for try await result in group {
      collected.append(result)
    }
    return collected
  }
  let elapsed = ContinuousClock.now - start
  #expect(results.count == 4)
  for result in results {
    #expect(result.exitCode == 0)
    #expect(result.stderr.count == 4_194_304)
    #expect(result.stdout.count == 4_194_304)
  }
  #expect(elapsed < .seconds(30), "elapsed \(elapsed.components.seconds)s")
}

@Test func cancellationBeforeLaunchThrowsAndChildNeverRuns() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let marker = directory.appendingPathComponent("marker")
  let runner = ResticRunner(executable: sh)
  let task = Task {
    try await runner.run(shInvocation("touch '" + marker.path + "'"), onLine: { _ in })
  }
  task.cancel()
  await #expect(throws: CancellationError.self) {
    _ = try await task.value
  }
  try await Task.sleep(for: .seconds(1))
  #expect(!FileManager.default.fileExists(atPath: marker.path))
}

@Test func rawStdoutBytesPreserved() async throws {
  let runner = ResticRunner(executable: sh)
  let withoutNewline = try await runner.run(shInvocation("printf 'ab'"), onLine: { _ in })
  #expect(withoutNewline.stdout == Data([0x61, 0x62]))
  let invalidUTF8 = try await runner.run(shInvocation(#"printf '\377\376'"#), onLine: { _ in })
  #expect(invalidUTF8.stdout == Data([0xFF, 0xFE]))
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

@Test func currentDirectorySetsWorkingDirectory() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let realPath = try #require(
    realpath(directory.path, nil).map { pointer in
      let value = String(cString: pointer)
      free(pointer)
      return value
    })
  let runner = ResticRunner(executable: URL(fileURLWithPath: "/bin/pwd"))
  let result = try await runner.run(
    ResticInvocation(
      arguments: [], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: directory.path),
    onLine: { _ in }
  )
  #expect(result.exitCode == 0)
  let printed = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  #expect(printed == realPath)
}

@Test func runWithoutCurrentDirectorySucceeds() async throws {
  let runner = ResticRunner(executable: URL(fileURLWithPath: "/bin/pwd"))
  let result = try await runner.run(
    ResticInvocation(arguments: [], environment: ["PATH": "/usr/bin:/bin"]),
    onLine: { _ in }
  )
  #expect(result.exitCode == 0)
  #expect(!String(decoding: result.stdout, as: UTF8.self).isEmpty)
}
