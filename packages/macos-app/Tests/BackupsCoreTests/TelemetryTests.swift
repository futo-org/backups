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
  (input: "could not read ~/Documents/a.txt from the queue", output: "could not read <path>"),
  (input: "no space left on device", output: "no space left on device"),
  (
    input: "7e4c1a52-0b6d-4f2a-9c3e-8d51f6b7a290",
    output: "7e4c1a52-0b6d-4f2a-9c3e-8d51f6b7a290"
  ),
  (
    input: "mkdir /Users/alice/My Folder/tax return.pdf: not a directory",
    output: "mkdir <path>: not a directory"
  ),
  (
    input: #"Fatal: --exclude: invalid pattern(s) provided: [invalid-/Users/alice/Client Files/tax.pdf"#,
    output: #"Fatal: --exclude: invalid pattern(s) provided: [invalid-<path>"#
  ),
  (
    input: #"open "/Users/alice/Secret Plans.txt": permission denied"#,
    output: #"open "<path>": permission denied"#
  ),
  (input: "cannot read ~/Documents/My Taxes 2025.pdf", output: "cannot read <path>"),
  (input: "two: /a b/c: first, /d e: second", output: "two: <path>: first, <path>: second"),
  (input: "http://localhost:3020/api/meta failed", output: "http://localhost:3020/api/meta failed"),
  (input: "keep-within 60d", output: "keep-within 60d"),
  (input: "/Users/x/Mom's Taxes, 2025/return.pdf", output: "<path>"),
  (
    input: "/Users/x/Mom's Taxes, 2025/return.pdf: permission denied",
    output: "<path>: permission denied"
  ),
  (input: "cannot read /Users/x/Photos (2024)/[draft] {v2}.jpg", output: "cannot read <path>"),
  (input: "lstat /Users/x/Café — 日本語/ファイル 🎉.pdf: no such file", output: "lstat <path>: no such file"),
  (
    input: #"{"item":"/Users/x/a, b's \"c\".txt","during":"archival"}"#,
    output: #"{"item":"<path>","during":"archival"}"#
  ),
  (input: #"{"item":"/Users/x/it's, here","during":"archival"}"#, output: #"{"item":"<path>","during":"archival"}"#),
  (input: "open '/Users/x/Mom's Taxes.pdf': permission denied", output: "open '<path>: permission denied"),
  (input: "The file “/Users/x/Mom's Taxes.pdf” couldn’t be opened.", output: "The file “<path>"),
  (input: "first /Users/x/a, b\nsecond /Users/x/c's d", output: "first <path>\nsecond <path>"),
  (input: "path=/Users/x/a b, c", output: "path=<path>"),
  (
    input: "/private/var/Snapshot/Volume/Users/x/f: open Users/x/Mom's Taxes, 2025/f: permission denied",
    output: "<path>: open <path>: permission denied"
  ),
  (
    input: "readdirent -weird/sub dir: input/output error",
    output: "readdirent <path>: input/output error"
  ),
  (
    input: "unable to open config file: Stat: 500 Internal Server Error",
    output: "unable to open config file: Stat: 500 Internal Server Error"
  ),
  (input: "3 / 4 files and/or 50/50", output: "3 / 4 files and/or 50/50"),
  (input: "cannot open file:///Users/x/Mom's%20Taxes,%202025/f.pdf: denied", output: "cannot open <path>: denied"),
  (
    input:
      #"UserInfo={NSFilePath=/Users/x/Mom's Taxes, 2025/return.pdf, NSUnderlyingError=0x6 {Error Domain=NSPOSIXErrorDomain Code=2 "No such file"}}"#,
    output:
      #"UserInfo={NSFilePath=<path>, NSUnderlyingError=0x6 {Error Domain=NSPOSIXErrorDomain Code=2 "No such file"}}"#
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
    log.data["items"] == .array([.string("mkdir <path>"), .int(3), .array([.string("<path>")])]))
  #expect(
    log.data["context"]
      == .object([
        "path": .string("<path>"), "ok": .bool(true), "at": .date(Date(timeIntervalSince1970: 0)),
      ]))
  #expect(log.data["version"] == .string("/Applications/Futo.app"))
  #expect(log.data["client"] == .string("macos"))
}
