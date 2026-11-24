import BackupsCore
import Foundation
import Testing

@Test("defaults expand home in excludes and keep globs verbatim")
func defaults() {
  let config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  #expect(AppConfig.devServerURL.absoluteString == "http://localhost:8081/.well-known/yucca.json")
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
      "/Users/test/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
      "/Users/test/Library/Containers/com.docker.docker/Data/vms",
      "/Users/test/Library/Application Support/rancher-desktop/lima",
      "/Users/test/Library/Application Support/Claude/vm_bundles",
      "/Users/test/.colima/_lima",
      "/Users/test/.lima/*/basedisk",
      "/Users/test/.lima/*/diffdisk",
      "/Users/test/.local/share/containers/podman/machine",
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

@Test("RunRecord saved before cloud-only skips existed decodes without them")
func decodeRunRecordWithoutCloudOnlySkips() throws {
  let json = #"{"startedAt":0,"finishedAt":5,"status":"complete","snapshotId":"abc","filesNew":3}"#
  let decoded = try JSONDecoder().decode(RunRecord.self, from: Data(json.utf8))
  #expect(decoded.status == .complete)
  #expect(decoded.snapshotId == "abc")
  #expect(decoded.cloudOnlySkipped == nil)
}

@Test("RunRecord round trips cloud-only skips")
func roundTripCloudOnlySkips() throws {
  let record = RunRecord(
    startedAt: Date(timeIntervalSince1970: 1_781_092_800),
    finishedAt: Date(timeIntervalSince1970: 1_781_092_805),
    status: .complete,
    cloudOnlySkipped: CloudOnlySkip(count: 12, bytes: 340_000_000, sample: ["/Users/test/Documents/ws.pptx"]))
  let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
  #expect(decoded == record)
  #expect(decoded.cloudOnlySkipped?.count == 12)
  #expect(decoded.cloudOnlySkipped?.bytes == 340_000_000)
  #expect(decoded.cloudOnlySkipped?.sample == ["/Users/test/Documents/ws.pptx"])
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

@Test(
  "server display name shows futo.cloud for production and host:port otherwise",
  arguments: [
    ("https://meta.futo.cloud/.well-known/yucca.json", "futo.cloud"),
    ("http://localhost:8081/.well-known/yucca.json", "localhost:8081"),
    ("http://localhost:3020/api/meta", "localhost:3020"),
    ("https://backups.example.org/.well-known/yucca.json", "backups.example.org"),
  ])
func serverDisplayName(url: String, expected: String) throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.serverURL = try #require(URL(string: url))
  #expect(config.serverDisplayName == expected)
}

@Test("a repository the account still lists is kept")
func forgetRepositoryKeepsListed() {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.repositoryId = "mine"
  config.recoveryKeyConfirmedAt = Date(timeIntervalSince1970: 1_781_092_800)
  config.lastRun = RunRecord(
    startedAt: Date(timeIntervalSince1970: 1_781_092_800),
    finishedAt: Date(timeIntervalSince1970: 1_781_093_100),
    status: .complete)
  let repositories = [
    RemoteRepository(id: "other", name: "other", worm: false),
    RemoteRepository(id: "mine", name: "book-pro", worm: false, connectionType: "restic"),
  ]
  let forgot = config.forgetRepository(unlessListedIn: repositories)
  #expect(!forgot)
  #expect(config.repositoryId == "mine")
  #expect(config.recoveryKeyConfirmedAt == Date(timeIntervalSince1970: 1_781_092_800))
  #expect(config.lastRun != nil)
}

@Test("a repository the account doesn't list is forgotten with its key confirmation")
func forgetRepositoryClearsUnlisted() {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.repositoryId = "previous-account"
  config.recoveryKeyConfirmedAt = Date(timeIntervalSince1970: 1_781_092_800)
  config.folders = ["/Users/test/Documents"]
  config.lastRun = RunRecord(
    startedAt: Date(timeIntervalSince1970: 1_781_092_800),
    finishedAt: Date(timeIntervalSince1970: 1_781_093_100),
    status: .complete)
  let forgot = config.forgetRepository(unlessListedIn: [RemoteRepository(id: "mine", name: "book-pro", worm: false)])
  #expect(forgot)
  #expect(config.repositoryId == nil)
  #expect(config.recoveryKeyConfirmedAt == nil)
  #expect(config.lastRun == nil)
  #expect(config.folders == ["/Users/test/Documents"])
  let forgotAgain = config.forgetRepository(unlessListedIn: [])
  #expect(!forgotAgain)
}

@Test("without a repository there is nothing to forget")
func forgetRepositoryWithoutRepository() {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.recoveryKeyConfirmedAt = Date(timeIntervalSince1970: 1_781_092_800)
  let forgot = config.forgetRepository(unlessListedIn: [])
  #expect(!forgot)
  #expect(config.recoveryKeyConfirmedAt == Date(timeIntervalSince1970: 1_781_092_800))
}

@Test func newInstallsGetEveryDefaultExcludeAndTheCurrentVersion() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  #expect(config.excludeDefaultsVersion == AppConfig.currentExcludeDefaultsVersion)
  #expect(config.excludes.contains("/Users/t/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"))
  #expect(config.excludes.contains("/Users/t/.lima/*/diffdisk"))
  let changed1 = config.addNewDefaultExcludes(home: "/Users/t")

  #expect(!changed1)
}

@Test func olderConfigsGainOnlyTheNewDefaultsOnce() throws {
  let json = """
    {"serverURL":"https://meta.futo.cloud/.well-known/yucca.json","folders":["/Users/t"],
     "excludes":["/Users/t/Library/Caches","*.iso","/Users/t/Library/Containers/com.docker.docker/Data/vms"],
     "schedule":{"kind":"manual"},"throttle":{"bytesPerSec":0,"quietHours":""},"host":"mac"}
    """
  var config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
  #expect(config.excludeDefaultsVersion == nil)
  let changed2 = config.addNewDefaultExcludes(home: "/Users/t")

  #expect(changed2)
  #expect(
    config.excludes.prefix(3) == [
      "/Users/t/Library/Caches", "*.iso", "/Users/t/Library/Containers/com.docker.docker/Data/vms",
    ])
  #expect(config.excludes.contains("/Users/t/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"))
  #expect(config.excludes.filter { $0.hasSuffix("com.docker.docker/Data/vms") }.count == 1)
  #expect(!config.excludes.contains("/Users/t/.Trash"))
  #expect(config.excludeDefaultsVersion == AppConfig.currentExcludeDefaultsVersion)
  let removed = config.excludes.filter { !$0.contains("orbstack") }
  config.excludes = removed
  let changed3 = config.addNewDefaultExcludes(home: "/Users/t")

  #expect(!changed3)
  #expect(!config.excludes.contains { $0.contains("orbstack") })
}

@Test func pinningToProductionForgetsAnotherServersRepository() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  config.repositoryId = "repo-1"
  let unchanged = config.pinToProductionServer()
  #expect(!unchanged)
  #expect(config.repositoryId == "repo-1")
  config.serverURL = AppConfig.devServerURL
  let pinned = config.pinToProductionServer()
  #expect(pinned)
  #expect(config.serverURL == AppConfig.productionServerURL)
  #expect(config.repositoryId == nil)
}
