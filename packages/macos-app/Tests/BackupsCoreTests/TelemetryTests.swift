import BackupsCore
import Foundation
import Testing

private func jsonObject(_ data: Data) throws -> Any {
  try JSONSerialization.jsonObject(with: data, options: [.allowFragments])
}

private let encodingCases: [(value: TelemetryValue, json: String)] = [
  (value: .string("hello"), json: #""hello""#),
  (value: .int(-4_294_967_296), json: "-4294967296"),
  (value: .bool(true), json: "true"),
  (value: .bool(false), json: "false"),
  (value: .date(Date(timeIntervalSince1970: 1_795_000_000.5)), json: #""2026-11-18T11:06:40.500Z""#),
  (value: .array([]), json: "[]"),
  (value: .array([.int(1), .string("a"), .bool(true), .array([.bool(false)])]), json: #"[1,"a",true,[false]]"#),
  (
    value: .object([
      "s": .string("x"), "i": .int(7), "b": .bool(true), "arr": .array([.string("z")]),
      "nested": .object(["x": .bool(false)]),
    ]),
    json: #"{"s":"x","i":7,"b":true,"arr":["z"],"nested":{"x":false}}"#,
  ),
]

@Test(arguments: encodingCases)
func telemetryValueEncodesToBareJSON(value: TelemetryValue, json: String) throws {
  let encoded = try JSONEncoder().encode(value)
  let actual = try jsonObject(encoded)
  let expected = try jsonObject(Data(json.utf8))
  #expect(actual as? NSObject == expected as? NSObject, "json: \(json)")
}

@Test func telemetryValueDateKeepsMillisecondsAndUTC() throws {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let date = try #require(formatter.date(from: "2026-11-22T15:23:08.250Z"))
  let encoded = try JSONEncoder().encode(TelemetryValue.date(date))
  #expect(String(data: encoded, encoding: .utf8) == #""2026-11-22T15:23:08.250Z""#)
}

@Test func telemetryValueErrorEncodesTypeAndMessage() throws {
  let error = EngineError.restic(code: 7, message: "disk full")
  let object = try #require(
    jsonObject(try JSONEncoder().encode(TelemetryValue.error(error))) as? [String: Any])
  #expect(Set(object.keys) == ["type", "message"])
  #expect(object["type"] as? String == "BackupsCore.EngineError")
  #expect(object["message"] as? String == #"restic(code: 7, message: "disk full")"#)
}

@Test func structuredLogOverridesCallerVersionAndClient() {
  let log = StructuredLog(
    summary: "Backup finished",
    data: ["version": .string("caller"), "client": .string("caller"), "repositoryId": .string("r-1")],
    version: "0.4.0")
  #expect(
    log.data
      == [
        "version": .string("0.4.0"),
        "client": .string("macos"),
        "repositoryId": .string("r-1"),
      ])
  #expect(StructuredLog.client == "macos")
  #expect(
    StructuredLog(summary: "x", data: ["a": .bool(true)], version: "1.0").data
      == ["a": .bool(true), "version": .string("1.0"), "client": .string("macos")])
}

@Test func structuredLogEncodesExactlySummaryAndData() throws {
  let log = StructuredLog(summary: "Created repository", data: ["repositoryId": .string("r-1")], version: "1.0.0")
  let object = try #require(jsonObject(try JSONEncoder().encode(log)) as? [String: Any])
  #expect(Set(object.keys) == ["summary", "data"])
  #expect(object["summary"] as? String == "Created repository")
  let data = try #require(object["data"] as? [String: Any])
  #expect(data["repositoryId"] as? String == "r-1")
  #expect(data["version"] as? String == "1.0.0")
  #expect(data["client"] as? String == "macos")
}

private let redactionCases: [(input: String, output: String)] = [
  (
    input: #"Fatal: --exclude: invalid pattern(s) provided: [invalid-/Users/alice/private-client/tax.pdf"#,
    output: #"Fatal: --exclude: invalid pattern(s) provided: [invalid-<path>"#
  ),
  (
    input: "cannot create target directory: mkdir /tmp/x/private-restore: not a directory",
    output: "cannot create target directory: mkdir <path>: not a directory"
  ),
  (
    input: #"""
    Error Domain=NSCocoaErrorDomain Code=4 “The file “x.txt” couldn’t be opened.” \
    UserInfo={NSFilePath=/Users/alice/private/x.txt, NSURL=file:///Users/alice/private/x.txt}
    """#,
    output: #"""
    Error Domain=NSCocoaErrorDomain Code=4 “The file “x.txt” couldn’t be opened.” \
    UserInfo={NSFilePath=<path>, NSURL=<path>}
    """#
  ),
  (
    input: "cannot open file:///var/db/repo/config failed",
    output: "cannot open <path> failed"
  ),
  (input: "https://user:secret@host/x", output: "https://***@host/x"),
  (input: "could not read ~/Documents/a.txt from the queue", output: "could not read <path> from the queue"),
  (input: "no space left on device", output: "no space left on device"),
  (
    input: "7e4c1a52-0b6d-4f2a-9c3e-8d51f6b7a290",
    output: "7e4c1a52-0b6d-4f2a-9c3e-8d51f6b7a290"
  ),
]

@Test(arguments: redactionCases)
func redactReplacesPathsWithPlaceholder(input: String, output: String) {
  #expect(StructuredLog.redact(input) == output)
}

@Test func structuredLogRedactsNestedStringValuesButNotSummaryVersionClient() {
  let log = StructuredLog(
    summary: "Backup finished after /Users/alice/secrets.txt changed",
    data: [
      "error": .string("cannot open /tmp/a/b.dat: denied"),
      "items": .array([.string("mkdir /var/x failed"), .int(3), .array([.string("~/y")])]),
      "context": .object([
        "path": .string("file:///private/etc/z"),
        "ok": .bool(true),
        "at": .date(Date(timeIntervalSince1970: 0)),
      ]),
    ],
    version: "/Applications/Futo.app")
  #expect(log.summary == "Backup finished after /Users/alice/secrets.txt changed")
  #expect(log.data["error"] == .string("cannot open <path>: denied"))
  #expect(
    log.data["items"] == .array([.string("mkdir <path> failed"), .int(3), .array([.string("<path>")])]))
  #expect(
    log.data["context"]
      == .object([
        "path": .string("<path>"), "ok": .bool(true), "at": .date(Date(timeIntervalSince1970: 0)),
      ]))
  #expect(log.data["version"] == .string("/Applications/Futo.app"))
  #expect(log.data["client"] == .string("macos"))
}
