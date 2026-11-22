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
