import BackupsCore
import Foundation
import Testing

private let apiRoot = URL(string: "https://server.example/api")!

private actor SleepRecorder {
  private(set) var sleeps: [Duration] = []

  func sleep(_ duration: Duration) {
    sleeps.append(duration)
  }
}

private func authorization(expiresIn: Int, interval: Int?) -> DeviceAuthorization {
  DeviceAuthorization(
    deviceCode: "dc-1", userCode: "UC-1", verificationUri: "https://server.example/activate",
    expiresIn: expiresIn, interval: interval)
}

private func login(responses: [HTTPResponse], expiresIn: Int, interval: Int?) -> (DeviceLogin, SleepRecorder) {
  let client = YuccaClient(
    apiRoot: apiRoot, transport: StubTransport(responses: responses), accessToken: nil)
  let recorder = SleepRecorder()
  let login = DeviceLogin(client: client) { duration in
    await recorder.sleep(duration)
  }
  return (login, recorder)
}

@Test func waitForTokenSucceedsAfterTwoPendingPolls() async throws {
  let (login, recorder) = login(
    responses: [
      jsonResponse(#"{"status":"PENDING"}"#),
      jsonResponse(#"{"status":"PENDING"}"#),
      jsonResponse(#"{"status":"SUCCESS","accessToken":"tok-42","userId":"u1"}"#),
    ],
    expiresIn: 600, interval: 5)
  let token = try await login.waitForToken(
    authorization(expiresIn: 600, interval: 5), connectionType: "macos", connectionName: "Alice's Mac")
  #expect(token == "tok-42")
  let sleeps = await recorder.sleeps
  #expect(sleeps == [.seconds(5), .seconds(5), .seconds(5)])
}

@Test func slowDownIncreasesSubsequentSleepsByFiveSeconds() async throws {
  let (login, recorder) = login(
    responses: [
      jsonResponse(#"{"status":"SLOW_DOWN"}"#),
      jsonResponse(#"{"status":"PENDING"}"#),
      jsonResponse(#"{"status":"SUCCESS","accessToken":"tok-7"}"#),
    ],
    expiresIn: 600, interval: 5)
  let token = try await login.waitForToken(
    authorization(expiresIn: 600, interval: 5), connectionType: "macos", connectionName: "Mac")
  #expect(token == "tok-7")
  let sleeps = await recorder.sleeps
  #expect(sleeps == [.seconds(5), .seconds(10), .seconds(10)])
}

@Test func failureReasonPropagatesAsFailedError() async throws {
  let (login, _) = login(
    responses: [jsonResponse(#"{"status":"FAILURE","reason":"EMAIL_NOT_ALLOWED"}"#)],
    expiresIn: 600, interval: 5)
  await #expect(throws: DeviceLoginError.failed(reason: "EMAIL_NOT_ALLOWED")) {
    _ = try await login.waitForToken(
      authorization(expiresIn: 600, interval: 5), connectionType: "macos", connectionName: "Mac")
  }
}

@Test func expiredAfterSummedSleepsReachExpiresIn() async throws {
  let (login, recorder) = login(
    responses: [
      jsonResponse(#"{"status":"PENDING"}"#),
      jsonResponse(#"{"status":"PENDING"}"#),
    ],
    expiresIn: 10, interval: 5)
  await #expect(throws: DeviceLoginError.expired) {
    _ = try await login.waitForToken(
      authorization(expiresIn: 10, interval: 5), connectionType: "macos", connectionName: "Mac")
  }
  let sleeps = await recorder.sleeps
  #expect(sleeps == [.seconds(5), .seconds(5)])
}

@Test func defaultIntervalIsFiveSecondsWhenMissing() async throws {
  let (login, recorder) = login(
    responses: [
      jsonResponse(#"{"status":"PENDING"}"#),
      jsonResponse(#"{"status":"SUCCESS","accessToken":"tok-3"}"#),
    ],
    expiresIn: 600, interval: nil)
  let token = try await login.waitForToken(
    authorization(expiresIn: 600, interval: nil), connectionType: "macos", connectionName: "Mac")
  #expect(token == "tok-3")
  let sleeps = await recorder.sleeps
  #expect(sleeps == [.seconds(5), .seconds(5)])
}

@Test(
  "login failures read as sentences naming the server",
  arguments: [
    (DeviceLoginError.expired, "The sign-in code expired. Try again."),
    (.failed(reason: "EXPIRED"), "The sign-in code expired. Try again."),
    (.failed(reason: "ACCESS_DENIED"), "Sign-in was declined in the browser."),
    (.failed(reason: "EMAIL_NOT_ALLOWED"), "This account can't use FUTO Backups yet."),
    (.failed(reason: "FEATURE_NOT_ENABLED"), "Mac backups aren't enabled for this account."),
    (.failed(reason: "UNSUPPORTED_CONNECTION_TYPE"), "futo.cloud doesn't support the Mac app yet."),
    (
      .failed(reason: "UNKNOWN"),
      "futo.cloud couldn't finish signing in this Mac. It may not support the Mac app yet."
    ),
    (.failed(reason: "SOMETHING_NEW"), "Sign-in failed (SOMETHING_NEW)."),
  ])
func loginFailureMessage(error: DeviceLoginError, expected: String) {
  #expect(error.message(server: "futo.cloud") == expected)
}
