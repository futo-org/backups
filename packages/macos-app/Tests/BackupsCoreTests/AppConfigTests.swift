import BackupsCore
import Foundation
import Testing

@Test("defaults expand home in excludes and keep globs verbatim")
func defaults() {
  let config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  #expect(AppConfig.devServerURL.absoluteString == "http://localhost:8080/.well-known/yucca.json")
  #expect(AppConfig.productionServerURL.absoluteString == "https://meta.futo.cloud/.well-known/yucca.json")
  #expect(config.serverURL == AppConfig.devServerURL)
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
}

@Test("AppConfig round trips through JSON with a lastRun")
func roundTripWithLastRun() throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.serverURL = AppConfig.productionServerURL
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
