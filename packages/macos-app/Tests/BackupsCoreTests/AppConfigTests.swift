import BackupsCore
import Foundation
import Testing

@Test("defaults expand home in excludes and keep globs verbatim")
func defaults() {
  let config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  #expect(AppConfig.devServerURL.absoluteString == "http://localhost:8080/.well-known/yucca.json")
  #expect(AppConfig.productionServerURL.absoluteString == "https://meta.futo.cloud/.well-known/yucca.json")
  #expect(config.serverURL == AppConfig.productionServerURL)
  #expect(config.folders == [])
  #expect(
    config.excludes == [
      "/Users/test/Library/Caches",
      "/Users/test/Library/Mobile Documents",
      "/Users/test/Library/CloudStorage",
      "/Users/test/Library/Containers/*/Data/Library/Caches",
      "/Users/test/.Trash",
      "**/node_modules",
      "**/.DS_Store",
    ])
  #expect(config.schedule == .daily(hour: 12, minute: 0))
  #expect(config.throttle == .unthrottled)
  #expect(config.host == "book-pro")
  #expect(config.repositoryId == nil)
  #expect(config.lastRun == nil)
  #expect(config.scheduleAnchor == nil)
  #expect(config.diskSnapshots == nil)
}

@Test("AppConfig round trips through JSON with a lastRun")
func roundTripWithLastRun() throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.serverURL = AppConfig.devServerURL
  config.folders = ["/Users/test/Documents", "/Users/test/Pictures"]
  config.repositoryId = "0b6a1f6e-3c1d-4c2a-9f7e-5d4b3a2c1e0f"
  config.schedule = .hourly
  config.throttle = Throttle(bytesPerSec: 1_048_576, quietHours: "22:00-07:00")
  config.lastRun = RunRecord(
    startedAt: Date(timeIntervalSince1970: 1_781_092_800),
    finishedAt: Date(timeIntervalSince1970: 1_781_093_100),
    status: .warn,
    snapshotId: "b1e3c9f0",
    filesNew: 12,
    dataAdded: 123_456_789,
    message: "lock file held"
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.dateEncodingStrategy = .iso8601
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(AppConfig.self, from: encoder.encode(config))
  #expect(decoded == config)
  #expect(decoded.lastRun?.startedAt == Date(timeIntervalSince1970: 1_781_092_800))
  #expect(decoded.lastRun?.status == .warn)
  #expect(decoded.lastRun?.snapshotId == "b1e3c9f0")
  #expect(decoded.lastRun?.filesNew == 12)
  #expect(decoded.lastRun?.dataAdded == 123_456_789)
  #expect(decoded.lastRun?.message == "lock file held")
}

@Test("optional RunRecord fields round trip as nil")
func roundTripBareRunRecord() throws {
  let record = RunRecord(
    startedAt: Date(timeIntervalSince1970: 1_781_092_800),
    finishedAt: Date(timeIntervalSince1970: 1_781_092_805),
    status: .failed
  )
  let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
  #expect(decoded == record)
  #expect(decoded.snapshotId == nil)
  #expect(decoded.filesNew == nil)
  #expect(decoded.dataAdded == nil)
  #expect(decoded.message == nil)
}

@Test("scheduleReference prefers lastRun then anchor then nil")
func scheduleReferencePrecedence() {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  #expect(config.scheduleReference == nil)
  let anchor = Date(timeIntervalSince1970: 1_700_000_000)
  config.scheduleAnchor = anchor
  #expect(config.scheduleReference == anchor)
  config.lastRun = RunRecord(
    startedAt: Date(timeIntervalSince1970: 1_700_003_600),
    finishedAt: Date(timeIntervalSince1970: 1_700_003_900),
    status: .complete
  )
  #expect(config.scheduleReference == Date(timeIntervalSince1970: 1_700_003_600))
}

@Test("config decodes without a scheduleAnchor key")
func decodeWithoutScheduleAnchor() throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.scheduleAnchor = Date(timeIntervalSince1970: 1_700_000_000)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.dateEncodingStrategy = .iso8601
  let object = try #require(
    try JSONSerialization.jsonObject(with: encoder.encode(config)) as? [String: Any])
  var stripped = object
  stripped.removeValue(forKey: "scheduleAnchor")
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: stripped))
  #expect(decoded.scheduleAnchor == nil)
  #expect(decoded.scheduleReference == nil)
  var expected = config
  expected.scheduleAnchor = nil
  #expect(decoded == expected)
}

@Test("anchoring the schedule defers the first run to the slot after the anchor")
func anchorSemantics() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = try #require(TimeZone(identifier: "Europe/Paris"))
  let anchor = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 9, minute: 0)))
  let noon = try #require(
    calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 12, minute: 0)))
  let daily = Schedule.daily(hour: 12, minute: 0)
  #expect(!daily.isDue(lastRun: anchor, now: anchor.addingTimeInterval(60), calendar: calendar))
  #expect(daily.isDue(lastRun: anchor, now: noon, calendar: calendar))
  #expect(Schedule.hourly.isDue(lastRun: noon, now: noon.addingTimeInterval(3660), calendar: calendar))
}

@Test func configWithoutRecoveryKeyConfirmationDecodesAsUnconfirmed() throws {
  let config = AppConfig.defaults(host: "Mac", home: "/Users/test")
  let encoder = JSONEncoder()
  var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(config)) as? [String: Any])
  object.removeValue(forKey: "recoveryKeyConfirmedAt")
  let legacy = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(AppConfig.self, from: legacy)
  #expect(decoded.recoveryKeyConfirmedAt == nil)
  #expect(decoded == config)
}

@Test("config JSON without a telemetryConsentedAt key decodes with nil")
func decodeWithoutTelemetryConsentedAt() throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.telemetryConsentedAt = Date(timeIntervalSince1970: 1_781_092_800)
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(config)) as? [String: Any])
  var stripped = object
  stripped.removeValue(forKey: "telemetryConsentedAt")
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: stripped))
  #expect(decoded.telemetryConsentedAt == nil)
  var expected = config
  expected.telemetryConsentedAt = nil
  #expect(decoded == expected)
}

@Test("round trip keeps a set telemetryConsentedAt and defaults leave it nil")
func roundTripTelemetryConsentedAt() throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  #expect(config.telemetryConsentedAt == nil)
  config.telemetryConsentedAt = Date(timeIntervalSince1970: 1_781_092_800)
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(AppConfig.self, from: encoder.encode(config))
  #expect(decoded == config)
  #expect(decoded.telemetryConsentedAt == Date(timeIntervalSince1970: 1_781_092_800))
}

@Test("config JSON without a diskSnapshots key decodes with nil and uses disk snapshots")
func decodeWithoutDiskSnapshots() throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.diskSnapshots = false
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let object = try #require(JSONSerialization.jsonObject(with: encoder.encode(config)) as? [String: Any])
  var stripped = object
  stripped.removeValue(forKey: "diskSnapshots")
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: stripped))
  #expect(decoded.diskSnapshots == nil)
  #expect(decoded.usesDiskSnapshots)
  var expected = config
  expected.diskSnapshots = nil
  #expect(decoded == expected)
}

@Test("diskSnapshots false round trips and defaults leave it nil")
func roundTripDiskSnapshots() throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  #expect(config.diskSnapshots == nil)
  #expect(config.usesDiskSnapshots)
  config.diskSnapshots = false
  let encoder = JSONEncoder()
  encoder.dateEncodingStrategy = .iso8601
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let decoded = try decoder.decode(AppConfig.self, from: encoder.encode(config))
  #expect(decoded == config)
  #expect(decoded.diskSnapshots == false)
  #expect(!decoded.usesDiskSnapshots)
}
