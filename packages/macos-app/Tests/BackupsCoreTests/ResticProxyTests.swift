import Foundation
import Testing

@testable import BackupsCore

private func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func makeScript(_ body: String, in directory: URL) throws -> URL {
  let url = directory.appendingPathComponent("fake-restic-proxy")
  try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  return url
}

private func waitForFileLines(_ url: URL, timeout: Duration = .seconds(5)) async throws -> [Substring] {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
      return text.split(separator: "\n", omittingEmptySubsequences: true)
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  Issue.record("file \(url.path) never became non-empty")
  return []
}

private struct Control: Decodable {
  struct Payload: Decodable {
    var bytesPerSec: Int
    var quietHours: String
  }

  var type: String
  var throttle: Payload
}

@Test func readyThrottleControlAndStop() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let outFile = directory.appendingPathComponent("control-out")
  let script = try makeScript(
    "printf '{\"address\":\"127.0.0.1:5555\",\"port\":5555}\\n' >&3\ncat <&3 > '" + outFile.path + "' &\n",
    in: directory)
  let launcher = ResticProxyLauncher(executable: script, readyTimeout: .seconds(10))
  let handle = try await launcher.start(
    apiRoot: URL(string: "http://127.0.0.1:9/api")!,
    throttle: .unthrottled)
  #expect(handle.address == "127.0.0.1:5555")
  try handle.setThrottle(Throttle(bytesPerSec: 1000, quietHours: "22:00-06:00"))
  await handle.stop()
  await handle.stop()
  let lines = try await waitForFileLines(outFile)
  #expect(lines.count == 1)
  let control = try JSONDecoder().decode(Control.self, from: Data(String(lines[0]).utf8))
  #expect(control.type == "throttle")
  #expect(control.throttle.bytesPerSec == 1000)
  #expect(control.throttle.quietHours == "22:00-06:00")
}

@Test func exitedBeforeReady() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = try makeScript("exit 0\n", in: directory)
  let launcher = ResticProxyLauncher(executable: script, readyTimeout: .seconds(5))
  await #expect(throws: ResticProxyError.notReady("exited before ready")) {
    _ = try await launcher.start(apiRoot: URL(string: "http://127.0.0.1:9/api")!, throttle: .unthrottled)
  }
}

@Test func readyTimeout() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let script = try makeScript("sleep 5\n", in: directory)
  let launcher = ResticProxyLauncher(executable: script, readyTimeout: .milliseconds(300))
  await #expect(throws: ResticProxyError.notReady("timeout")) {
    _ = try await launcher.start(apiRoot: URL(string: "http://127.0.0.1:9/api")!, throttle: .unthrottled)
  }
}

@Test func environmentMatchesSpawnContract() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let outFile = directory.appendingPathComponent("env-out")
  let dump =
    "{ echo \"API=$RESTIC_PROXY_API_URL\"; echo \"HOST=$RESTIC_PROXY_HOST\"; echo \"PORT=$RESTIC_PROXY_PORT\"; "
    + "echo \"READY=$RESTIC_PROXY_READY_FD\"; echo \"BYTES=$RESTIC_PROXY_THROTTLE_BYTES_PER_SEC\"; "
    + "echo \"QUIET=$RESTIC_PROXY_THROTTLE_QUIET_HOURS\"; echo \"LOGFMT=$LOG_FORMAT\"; echo \"LOGLEVEL=$LOG_LEVEL\"; } > '"
    + outFile.path + "'"
  let script = try makeScript(
    dump + "\nprintf '{\"address\":\"127.0.0.1:7777\",\"port\":7777}\\n' >&3\ncat <&3 &\nwait\n",
    in: directory)
  let launcher = ResticProxyLauncher(executable: script, readyTimeout: .seconds(10))
  let handle = try await launcher.start(
    apiRoot: URL(string: "http://127.0.0.1:9/api/")!,
    throttle: Throttle(bytesPerSec: 4242, quietHours: "22:00-06:00"))
  #expect(handle.address == "127.0.0.1:7777")
  let lines = try await waitForFileLines(outFile)
  await handle.stop()
  #expect(
    lines.map(String.init) == [
      "API=http://127.0.0.1:9/api",
      "HOST=127.0.0.1",
      "PORT=0",
      "READY=3",
      "BYTES=4242",
      "QUIET=22:00-06:00",
      "LOGFMT=json",
      "LOGLEVEL=info",
    ])
}

@Test func repositoryURLFormat() {
  #expect(
    resticProxyRepositoryURL(address: "127.0.0.1:54321", repositoryId: "repo-id", accessToken: "access token")
      == "rest:http://repo-id:access token@127.0.0.1:54321")
}
