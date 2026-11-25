import Foundation
import Testing

@testable import BackupsCore

private let server = "FUTO Cloud"
private let unreachable = "Could not connect to FUTO Cloud. Make sure that this Mac is connected to the internet."
private let offline = "This Mac is offline. Connect it to the internet, then try again."
private let insecure =
  "Could not connect securely to FUTO Cloud. Make sure that the network and the date and time on this Mac are correct."

private let reportedTimeout = NSError(
  domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
  userInfo: [
    "_kCFStreamErrorCodeKey": -2102,
    NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainCFNetwork", code: -1001),
    NSLocalizedDescriptionKey: "The request timed out.",
    NSURLErrorFailingURLErrorKey: URL(string: "https://meta.futo.cloud/.well-known/yucca.json")!,
  ])

private func wrapping(_ underlying: any Error) -> NSError {
  NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: underlying as NSError])
}

struct ErrorCase: Sendable, CustomTestStringConvertible {
  let error: any Error
  let expected: String?

  init(_ error: any Error, _ expected: String?) {
    self.error = error
    self.expected = expected
  }

  var testDescription: String { "\(type(of: error)) → \(expected ?? "nil")" }
}

struct FlaggedError: Sendable, CustomTestStringConvertible {
  let error: any Error
  let flag: Bool

  init(_ error: any Error, _ flag: Bool) {
    self.error = error
    self.flag = flag
  }

  var testDescription: String { "\(type(of: error)) → \(flag)" }
}

@Test(arguments: [
  ErrorCase(URLError(.timedOut), unreachable),
  ErrorCase(URLError(.cannotFindHost), unreachable),
  ErrorCase(URLError(.cannotConnectToHost), unreachable),
  ErrorCase(URLError(.dnsLookupFailed), unreachable),
  ErrorCase(URLError(.networkConnectionLost), unreachable),
  ErrorCase(URLError(.notConnectedToInternet), offline),
  ErrorCase(URLError(.dataNotAllowed), offline),
  ErrorCase(URLError(.secureConnectionFailed), insecure),
  ErrorCase(URLError(.serverCertificateUntrusted), insecure),
  ErrorCase(URLError(.serverCertificateHasBadDate), insecure),
  ErrorCase(reportedTimeout, unreachable),
  ErrorCase(wrapping(URLError(.cannotConnectToHost)), unreachable),
  ErrorCase(wrapping(wrapping(URLError(.notConnectedToInternet))), offline),
  ErrorCase(CancellationError(), nil),
  ErrorCase(URLError(.cancelled), nil),
  ErrorCase(wrapping(URLError(.cancelled)), nil),
  ErrorCase(EngineError.busy, "Another operation is running"),
  ErrorCase(EngineError.missingMasterKey, "This Mac's recovery key is missing"),
  ErrorCase(EngineError.restic(code: 1, message: "repository is locked"), "repository is locked"),
  ErrorCase(YuccaError.unauthorized, "Your session expired. Sign in again."),
  ErrorCase(YuccaError.http(status: 503, body: "<html>"), "The server returned an error (HTTP 503). Try again later."),
  ErrorCase(YuccaError.http(status: 429, body: ""), "The server returned an error (HTTP 429). Try again later."),
  ErrorCase(YuccaError.http(status: 403, body: ""), "The server returned an error (HTTP 403)."),
  ErrorCase(
    YuccaError.invalidDiscovery("no discovery document"),
    "The server address is not a FUTO Backups server. Make sure that the address is correct."),
  ErrorCase(YuccaError.insecureDiscovery("server URL must use https"), "The server address must use HTTPS."),
  ErrorCase(
    EngineError.restic(code: 1, message: "Fatal: unable to open config file: unexpected HTTP response (503)"),
    ConnectionFailure.unavailable.message(server: server)),
  ErrorCase(YuccaError.decoding("keyNotFound"), "FUTO Backups could not read the response from the server."),
  ErrorCase(DeviceLoginError.expired, "The sign-in code expired. Try again."),
  ErrorCase(
    DeviceLoginError.failed(reason: "UNSUPPORTED_CONNECTION_TYPE"), "FUTO Cloud does not support the Mac app yet."),
  ErrorCase(DiskSnapshotError.unavailable, "Disk snapshots are unavailable."),
  ErrorCase(CloudOnlyError.everyFolderIsCloudOnly, CloudOnlyError.everyFolderIsCloudOnly.description),
  ErrorCase(
    RepositoryKeysError.invalidMasterKey, "That recovery key is not valid. Make sure that you entered it correctly."),
  ErrorCase(SecretStoreError.keychain(-25300), "FUTO Backups could not use the keychain (error -25300)."),
  ErrorCase(
    ResticProxyError.notReady("exited"), "The backup helper could not start. Try again, or reinstall FUTO Backups."),
  ErrorCase(
    NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [NSLocalizedDescriptionKey: "No permission."]),
    "No permission."),
  ErrorCase(RestoreIncomplete(restored: [], cause: URLError(.timedOut)), unreachable),
  ErrorCase(
    RestoreIncomplete(
      restored: [URL(fileURLWithPath: "/r/a")], leftoverStaging: URL(fileURLWithPath: "/r/.staging"),
      cause: URLError(.cancelled)),
    "Restore canceled. FUTO Backups restored 1 item before the restore stopped. "
      + "FUTO Backups could not remove the temporary folder /r/.staging"),
  ErrorCase(
    RestoreIncomplete(
      restored: [URL(fileURLWithPath: "/r/a"), URL(fileURLWithPath: "/r/b")], cause: CancellationError()),
    "Restore canceled. FUTO Backups restored 2 items before the restore stopped"),
])
func userFacingText(_ testCase: ErrorCase) {
  #expect(ErrorMessage.text(for: testCase.error, server: server) == testCase.expected)
}

@Test(arguments: [
  FlaggedError(URLError(.timedOut), true),
  FlaggedError(URLError(.networkConnectionLost), true),
  FlaggedError(URLError(.cannotConnectToHost), true),
  FlaggedError(URLError(.cannotFindHost), true),
  FlaggedError(URLError(.dnsLookupFailed), true),
  FlaggedError(wrapping(URLError(.timedOut)), true),
  FlaggedError(reportedTimeout, true),
  FlaggedError(URLError(.cancelled), false),
  FlaggedError(CancellationError(), false),
  FlaggedError(URLError(.notConnectedToInternet), false),
  FlaggedError(URLError(.secureConnectionFailed), false),
  FlaggedError(URLError(.serverCertificateUntrusted), false),
  FlaggedError(YuccaError.http(status: 502, body: ""), false),
  FlaggedError(YuccaError.decoding("bad"), false),
])
func transientFailures(_ testCase: FlaggedError) {
  #expect(ConnectionFailure.isTransient(testCase.error) == testCase.flag)
}

@Test(arguments: [
  ("unexpected HTTP response (502): 502 Bad Gateway", ConnectionFailure.unreachable),
  ("Fatal: unable to open config file: unexpected HTTP response (503): 503 Service Unavailable", .unavailable),
  ("unexpected HTTP response (504): 504 Gateway Timeout", .unreachable),
  ("unexpected HTTP response (500): 500 Internal Server Error", nil),
  ("unexpected HTTP response (404): 404 Not Found", nil),
  ("repository is locked", nil),
  ("wrong password or no key found", nil),
])
func resticConnectivityFailures(_ message: String, _ expected: ConnectionFailure?) {
  #expect(ConnectionFailure(resticError: message) == expected)
}

@Test(arguments: ConnectionFailure.allCases, ["FUTO Cloud", "futo.cloud", "localhost:8081"])
func recordedConnectionMessagesAreRecognised(_ failure: ConnectionFailure, server: String) {
  #expect(ConnectionFailure(message: failure.message(server: server)) == failure)
}

@Test(arguments: [
  "Could not connect to . Make sure that this Mac is connected to the internet.",
  "Could not connect to FUTO Cloud.",
  "Could not delete old snapshots: The request timed out.",
  "repository is locked",
  String(describing: reportedTimeout),
  "",
])
func otherMessagesAreNotConnectionFailures(_ message: String) {
  #expect(ConnectionFailure(message: message) == nil)
}

@Test func messagesAreShortAndHaveNoEllipses() {
  let texts =
    ConnectionFailure.allCases.map { $0.message(server: server) }
    + [
      YuccaError.invalidDiscovery("x"), .insecureDiscovery("x"), .unauthorized, .http(status: 500, body: ""),
      .decoding("x"),
    ].compactMap(\.errorDescription)
  for text in texts {
    #expect(!text.contains("…") && !text.contains("..."))
    #expect(text.count < 120)
    #expect(text.first?.isUppercase == true)
  }
}

@Test(arguments: [
  FlaggedError(YuccaError.unauthorized, true),
  FlaggedError(RestoreIncomplete(restored: [], cause: YuccaError.unauthorized), true),
  FlaggedError(YuccaError.http(status: 403, body: ""), false),
  FlaggedError(URLError(.timedOut), false),
])
func signingOut(_ testCase: FlaggedError) {
  #expect(ErrorMessage.signsOut(testCase.error) == testCase.flag)
}

@Test(arguments: [
  FlaggedError(CancellationError(), true),
  FlaggedError(URLError(.cancelled), true),
  FlaggedError(wrapping(URLError(.cancelled)), true),
  FlaggedError(URLError(.timedOut), false),
  FlaggedError(EngineError.busy, false),
])
func cancellation(_ testCase: FlaggedError) {
  #expect(ErrorMessage.isCancellation(testCase.error) == testCase.flag)
}

@Test func diagnosticsLabelNamesTheErrorCaseWithoutItsDetails() {
  #expect(
    EngineDiagnostics.label(of: YuccaError.invalidDiscovery("https://user:secret@example.org/x"))
      == "YuccaError.invalidDiscovery")
  #expect(EngineDiagnostics.label(of: YuccaError.unauthorized) == "YuccaError.unauthorized")
  #expect(
    !EngineDiagnostics.label(
      of: URLError(.timedOut, userInfo: [NSURLErrorKey: URL(string: "https://user:secret@example.org")!])
    ).contains("secret"))
}
