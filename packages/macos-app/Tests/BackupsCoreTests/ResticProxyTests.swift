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

@Test func networkChangedWritesAControlLine() async throws {
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
  try handle.networkChanged()
  await handle.stop()
  let lines = try await waitForFileLines(outFile)
  #expect(lines == [#"{"type":"network-changed"}"#])
}

private struct HandleWithoutNetworkReset: ResticProxyHandle {
  let address = "127.0.0.1:1"
  let uploadedBytes: Int64 = 0
  func setThrottle(_ throttle: Throttle) throws {}
  func stop() async {}
}

@Test func handlesWithoutANetworkResetIgnoreNetworkChanges() throws {
  let handle: any ResticProxyHandle = HandleWithoutNetworkReset()
  try handle.networkChanged()
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
    + "echo \"READY=$RESTIC_PROXY_READY_FD\"; echo \"PROGRESS=$RESTIC_PROXY_PROGRESS_INTERVAL_MS\"; echo \"BYTES=$RESTIC_PROXY_THROTTLE_BYTES_PER_SEC\"; "
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
      "PROGRESS=500",
      "BYTES=4242",
      "QUIET=22:00-06:00",
      "LOGFMT=json",
      "LOGLEVEL=info",
    ])
}

@Test func throttleAfterProxyGoneThrowsAndStopReturns() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let marker = directory.appendingPathComponent("closed")
  let script = try makeScript(
    "printf '{\"address\":\"127.0.0.1:5555\",\"port\":5555}\\n' >&3\nexec 3>&-\ntouch '" + marker.path
      + "'\nexit 0\n",
    in: directory)
  let launcher = ResticProxyLauncher(executable: script, readyTimeout: .seconds(10))
  let handle = try await launcher.start(
    apiRoot: URL(string: "http://127.0.0.1:9/api")!,
    throttle: .unthrottled)
  #expect(handle.address == "127.0.0.1:5555")
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(FileManager.default.fileExists(atPath: marker.path))
  var thrown: (any Error)?
  do {
    try handle.setThrottle(Throttle(bytesPerSec: 100, quietHours: ""))
  } catch {
    thrown = error
  }
  #expect(thrown != nil)
  await handle.stop()
}

@Test func progressLinesAfterReadyUpdateUploadedBytesAndThrottleStillWrites() async throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let outFile = directory.appendingPathComponent("control-out")
  let script = try makeScript(
    #"printf '{"address":"127.0.0.1:5555","port":5555}\n' >&3"# + "\n"
      + #"printf '{"type":"progress","uploadedBytes":1024}\n{"type":"future"}\nnot json\n' >&3"# + "\n"
      + #"printf '{"type":"progress","uploadedBytes":16777216}\n' >&3"# + "\n"
      + "cat <&3 > '" + outFile.path + "' &\n",
    in: directory)
  let launcher = ResticProxyLauncher(executable: script, readyTimeout: .seconds(10))
  let handle = try await launcher.start(
    apiRoot: URL(string: "http://127.0.0.1:9/api")!,
    throttle: .unthrottled)
  #expect(handle.address == "127.0.0.1:5555")
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  while handle.uploadedBytes != 16_777_216, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(handle.uploadedBytes == 16_777_216)
  try handle.setThrottle(Throttle(bytesPerSec: 2048, quietHours: ""))
  await handle.stop()
  let lines = try await waitForFileLines(outFile)
  #expect(lines.count == 1)
  let control = try JSONDecoder().decode(Control.self, from: Data(String(lines[0]).utf8))
  #expect(control.throttle.bytesPerSec == 2048)
}

@Test func proxyMessagesYieldTheLatestProgressAcrossChunks() {
  var messages = ResticProxyMessages()
  #expect(messages.latestUploadedBytes(after: Array(#"{"type":"progress","upl"#.utf8)) == nil)
  let middle = #"oadedBytes":10}"# + "\n" + #"{"type":"progress","uploadedBytes":20}"# + "\n" + #"{"type":"pro"#
  #expect(messages.latestUploadedBytes(after: Array(middle.utf8)) == 20)
  #expect(messages.latestUploadedBytes(after: Array((#"gress","uploadedBytes":30}"# + "\n").utf8)) == 30)
}

@Test func proxyMessagesSkipUnknownMalformedAndOversizedLines() {
  var messages = ResticProxyMessages()
  let skipped = #"{"type":"throttle","throttle":{"bytesPerSec":1}}"# + "\ngarbage\n" + #"{"type":"progress"}"# + "\n"
  #expect(messages.latestUploadedBytes(after: Array(skipped.utf8)) == nil)
  let oversized = Array(repeating: UInt8(ascii: "x"), count: ResticProxyMessages.maxLineLength + 10) + [0x0A]
  #expect(messages.latestUploadedBytes(after: oversized) == nil)
  let next = #"{"type":"progress","uploadedBytes":7}"# + "\n"
  #expect(messages.latestUploadedBytes(after: Array(next.utf8)) == 7)
}

@Test(
  "pollTimeoutMilliseconds table",
  arguments: [
    (Duration.zero, Int32(0)),
    (Duration.milliseconds(-500), Int32(0)),
    (Duration.seconds(-2), Int32(0)),
    (Duration.nanoseconds(1), Int32(1)),
    (Duration.milliseconds(250), Int32(250)),
    (Duration.seconds(1_000_000_000), Int32.max),
  ])
func pollTimeoutMillisecondsTable(_ input: (Duration, Int32)) {
  #expect(ResticProxyLauncher.pollTimeoutMilliseconds(input.0) == input.1)
}

@Test func repositoryURLFormat() {
  #expect(
    resticProxyRepositoryURL(address: "127.0.0.1:54321", repositoryId: "repo-id", accessToken: "access token")
      == "rest:http://repo-id:access token@127.0.0.1:54321")
}
