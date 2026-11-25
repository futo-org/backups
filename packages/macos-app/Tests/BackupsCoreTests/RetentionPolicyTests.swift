import BackupsCore
import Foundation
import Testing

@Test("presets mirror the Immich integration and default to 60 days")
func presets() {
  #expect(
    RetentionPreset.allCases.map(\.label) == [
      "After 15 days", "After 30 days", "After 60 days", "After 90 days", "Keep latest two backups",
      "Never (keep all backups)",
    ])
  #expect(RetentionPreset.days15.retention == .policy(RetentionPolicy(keepWithin: "15d")))
  #expect(RetentionPreset.latestTwo.retention == .policy(RetentionPolicy(keepLast: 2)))
  #expect(RetentionPreset.never.retention == .keepAll)
  #expect(RetentionPreset.standard.retention == SnapshotRetention.standard)
  #expect(SnapshotRetention.standard == .policy(RetentionPolicy(keepWithin: "60d")))
  #expect(RetentionPreset(.policy(RetentionPolicy(keepWithin: "90d"))) == .days90)
  #expect(RetentionPreset(.policy(RetentionPolicy(keepWithin: "45d"))) == nil)
}

@Test("a config without retention keeps the 60-day default")
func configDefaultsToSixtyDays() throws {
  let config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  #expect(config.retention == nil)
  #expect(config.snapshotRetention == .standard)
  let json = try JSONEncoder().encode(config)
  #expect(!String(decoding: json, as: UTF8.self).contains("retention"))
  let decoded = try JSONDecoder().decode(AppConfig.self, from: json)
  #expect(decoded.retention == nil)
  #expect(decoded.snapshotRetention == .standard)
}

@Test(
  "explicit retention round trips through the config, distinct from the default",
  arguments: [
    SnapshotRetention.keepAll,
    .standard,
    .policy(RetentionPolicy(keepLast: 2)),
    .policy(RetentionPolicy(keepLast: 3, keepWithinHourly: "2d", keepWithinDaily: "1m", keepWithinYearly: "10y")),
  ])
func retentionRoundTrips(retention: SnapshotRetention) throws {
  var config = AppConfig.defaults(host: "book-pro", home: "/Users/test")
  config.retention = retention
  let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
  #expect(decoded.retention == retention)
  #expect(decoded == config)
}

@Test("retention encodes as the orchestration API policy shape, or keepAll")
func retentionEncoding() throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  let encode = { (retention: SnapshotRetention) in String(decoding: try encoder.encode(retention), as: UTF8.self) }
  #expect(try encode(.keepAll) == #"{"keepAll":true}"#)
  #expect(try encode(.standard) == #"{"keepWithin":"60d"}"#)
  #expect(try encode(.policy(RetentionPolicy(keepLast: 2))) == #"{"keepLast":2}"#)
  let decoded = try JSONDecoder().decode(SnapshotRetention.self, from: Data(#"{"keepAll":false,"keepLast":5}"#.utf8))
  #expect(decoded == .policy(RetentionPolicy(keepLast: 5)))
}

@Test(
  "durations accept restic's units in any order and normalise them",
  arguments: [
    ("60d", RetentionDuration(days: 60), "60d"),
    (" 1y2m3d4h ", RetentionDuration(years: 1, months: 2, days: 3, hours: 4), "1y2m3d4h"),
    ("4h3d2m1y", RetentionDuration(years: 1, months: 2, days: 3, hours: 4), "1y2m3d4h"),
    ("1d2y", RetentionDuration(years: 2, days: 1), "2y1d"),
    ("2h1d", RetentionDuration(days: 1, hours: 2), "1d2h"),
    ("6m", RetentionDuration(months: 6), "6m"),
    ("0y5d", RetentionDuration(days: 5), "5d"),
    ("012h", RetentionDuration(hours: 12), "12h"),
    ("9999y", RetentionDuration(years: 9999), "9999y"),
  ])
func durationParses(text: String, duration: RetentionDuration, canonical: String) throws {
  let parsed = try RetentionDuration(parsing: text)
  #expect(parsed == duration)
  #expect(parsed.text == canonical)
}

@Test(
  "durations reject anything restic would refuse or misread",
  arguments: [
    ("", RetentionInputError.invalidDuration),
    ("60", .invalidDuration),
    ("d", .invalidDuration),
    ("1w", .invalidDuration),
    ("2D", .invalidDuration),
    ("-1d", .invalidDuration),
    ("1.5d", .invalidDuration),
    ("1d1d", .invalidDuration),
    ("1d2h1d", .invalidDuration),
    ("0d1d", .invalidDuration),
    ("1d 2h", .invalidDuration),
    ("0d", .zeroDuration),
    ("0y0m0d0h", .zeroDuration),
    ("10000d", .durationTooLong),
    ("99999999999999999999d", .durationTooLong),
  ])
func durationRejects(text: String, error: RetentionInputError) {
  #expect(throws: error) {
    try RetentionDuration(parsing: text)
  }
}

@Test(
  "durations describe themselves in words",
  arguments: [
    (RetentionDuration(days: 60), "60 days"),
    (RetentionDuration(days: 1), "1 day"),
    (RetentionDuration(years: 1, months: 6), "1 year and 6 months"),
    (RetentionDuration(years: 2, months: 1, days: 3, hours: 4), "2 years, 1 month, 3 days and 4 hours"),
  ])
func durationDescription(duration: RetentionDuration, text: String) {
  #expect(duration.description == text)
}

@Test(
  "policies describe themselves for the UI",
  arguments: [
    (SnapshotRetention.standard, "Keep the last 60 days"),
    (.policy(RetentionPolicy(keepLast: 2)), "Keep the latest 2 backups"),
    (.policy(RetentionPolicy(keepLast: 1)), "Keep the latest backup"),
    (.keepAll, "Keep all snapshots"),
    (
      .policy(RetentionPolicy(keepWithinHourly: "2d", keepWithinDaily: "1m", keepWithinWeekly: "6m")),
      "Hourly for 2 days, daily for 1 month, weekly for 6 months"
    ),
    (
      .policy(RetentionPolicy(keepLast: 3, keepWithin: "7d", keepWithinYearly: "10y")),
      "Latest 3 backups, all for 7 days, yearly for 10 years"
    ),
    (.policy(RetentionPolicy()), "Keep all snapshots until you correct the retention setting"),
  ])
func retentionSummary(retention: SnapshotRetention, summary: String) {
  #expect(retention.summary == summary)
}

@Test("telemetry names the restic rules without paths")
func telemetryValue() {
  #expect(SnapshotRetention.standard.telemetryValue == "keep-within 60d")
  #expect(SnapshotRetention.keepAll.telemetryValue == "keep-all")
  #expect(
    SnapshotRetention.policy(RetentionPolicy(keepLast: 2, keepWithinMonthly: "2y")).telemetryValue
      == "keep-last 2, keep-within-monthly 2y")
  #expect(SnapshotRetention.policy(RetentionPolicy()).telemetryValue == "invalid")
}

@Test(
  "policy validation checks every rule and requires at least one",
  arguments: [
    (RetentionPolicy(), RetentionInputError.noRules),
    (RetentionPolicy(keepLast: 0), .notAPositiveNumber),
    (RetentionPolicy(keepLast: -2), .notAPositiveNumber),
    (RetentionPolicy(keepLast: 100_001), .numberTooLarge),
    (RetentionPolicy(keepLast: 2, keepWithinWeekly: "1w"), .invalidDuration),
    (RetentionPolicy(keepWithinYearly: "0y"), .zeroDuration),
  ])
func policyValidation(policy: RetentionPolicy, error: RetentionInputError) {
  #expect(throws: error) {
    try policy.validated()
  }
}

@Test("validation normalises durations to restic's canonical form")
func policyValidationNormalises() throws {
  let policy = RetentionPolicy(keepLast: 2, keepWithin: " 012d ", keepWithinMonthly: "0y2m")
  let validated = try policy.validated()
  #expect(validated.policy == RetentionPolicy(keepLast: 2, keepWithin: "12d", keepWithinMonthly: "2m"))
  #expect(validated.resticArguments == ["--keep-last", "2", "--keep-within", "12d", "--keep-within-monthly", "2m"])
}

@Test(
  "stricter retention needs confirmation, looser retention does not",
  arguments: [
    (SnapshotRetention.standard, SnapshotRetention.standard, false),
    (.standard, RetentionPreset.days90.retention, false),
    (.standard, .keepAll, false),
    (.standard, RetentionPreset.days30.retention, true),
    (.standard, RetentionPreset.latestTwo.retention, true),
    (.keepAll, .standard, true),
    (.policy(RetentionPolicy(keepLast: 2)), .policy(RetentionPolicy(keepLast: 3)), false),
    (.policy(RetentionPolicy(keepLast: 2)), .policy(RetentionPolicy(keepLast: 1)), true),
    (.policy(RetentionPolicy(keepLast: 2)), .standard, true),
    (.standard, .policy(RetentionPolicy(keepWithin: "2m")), true),
    (.standard, .policy(RetentionPolicy(keepWithin: "3m")), false),
    (.standard, .policy(RetentionPolicy(keepWithinDaily: "1y")), true),
    (.policy(RetentionPolicy(keepWithinDaily: "1m")), .policy(RetentionPolicy(keepWithin: "1y")), false),
    (.policy(RetentionPolicy(keepWithinDaily: "1m")), .policy(RetentionPolicy(keepWithinDaily: "2m")), false),
    (.policy(RetentionPolicy(keepWithinDaily: "2m")), .policy(RetentionPolicy(keepWithinDaily: "1m")), true),
    (
      .policy(RetentionPolicy(keepLast: 2, keepWithinDaily: "1m")),
      .policy(RetentionPolicy(keepLast: 2, keepWithin: "7d", keepWithinDaily: "1m", keepWithinYearly: "5y")), false
    ),
    (.policy(RetentionPolicy()), .standard, true),
    (.standard, .policy(RetentionPolicy()), false),
  ])
func stricterRetention(current: SnapshotRetention, proposed: SnapshotRetention, mayDeleteMore: Bool) {
  #expect(proposed.mayDeleteMore(than: current) == mayDeleteMore)
}

@Test(
  "calendar units only cover elapsed hours with a day to spare for DST and time zone changes",
  arguments: [
    ("24h", "1d", true),
    ("1d", "24h", true),
    ("25h", "1d1h", true),
    ("47h", "1d", true),
    ("1d", "48h", false),
    ("720h", "1m", true),
    ("1m", "768h", false),
    ("8760h", "1y", true),
    ("365d", "1y", false),
    ("1y", "365d", true),
    ("366d", "1y", true),
    ("1m", "31d", false),
    ("1m", "30d", true),
    ("28d", "1m", false),
    ("29d", "1m", true),
    ("2d", "1d23h", true),
    ("2h1d", "1d2h", false),
    ("1d2h", "1d", true),
    ("1d", "1d2h", false),
  ])
func calendarVersusElapsed(current: String, proposed: String, mayDeleteMore: Bool) {
  let retention = { (within: String) in SnapshotRetention.policy(RetentionPolicy(keepWithin: within)) }
  #expect(retention(proposed).mayDeleteMore(than: retention(current)) == mayDeleteMore)
}

@Test(
  "resuming a backup confirms any policy that can delete this Mac's snapshots",
  arguments: [
    (RetentionPreset.latestTwo, ["mac"] as [String]?, true),
    (.days60, ["mac", "other"], true),
    (.days15, nil, true),
    (.latestTwo, ["other"], false),
    (.latestTwo, [], false),
    (.never, ["mac"], false),
    (.never, nil, false),
  ])
func resumedSnapshots(preset: RetentionPreset, hostnames: [String]?, mayDelete: Bool) {
  #expect(preset.retention.mayDeleteResumedSnapshots(hostnames: hostnames, host: "mac") == mayDelete)
}

@Test("a draft starts from the policy and produces a validated policy")
func draftRoundTrip() throws {
  let policy = RetentionPolicy(keepLast: 3, keepWithinDaily: "1m")
  var draft = RetentionDraft(policy)
  #expect(draft[.last] == "3")
  #expect(draft[.daily] == "1m")
  #expect(draft[.within] == "")
  #expect(try draft.policy() == policy)
  draft[.last] = ""
  draft[.yearly] = " 10y "
  #expect(try draft.policy() == RetentionPolicy(keepWithinDaily: "1m", keepWithinYearly: "10y"))
  #expect(draft.errors.isEmpty)
}

@Test("a draft reports an error for each invalid field")
func draftErrors() {
  var draft = RetentionDraft()
  draft[.last] = "two"
  draft[.within] = "60"
  draft[.hourly] = "0h"
  draft[.weekly] = "4w"
  #expect(
    draft.errors == [
      .last: .notAPositiveNumber, .within: .invalidDuration, .hourly: .zeroDuration, .weekly: .invalidDuration,
    ])
  #expect(throws: RetentionInputError.notAPositiveNumber) {
    try draft.policy()
  }
}

@Test(
  "a draft's keep-last field accepts only positive whole numbers",
  arguments: [
    ("0", RetentionInputError.notAPositiveNumber),
    ("-1", .notAPositiveNumber),
    ("1.5", .notAPositiveNumber),
    ("100001", .numberTooLarge),
    ("99999999999999999999", .numberTooLarge),
  ])
func draftKeepLast(text: String, error: RetentionInputError) {
  var draft = RetentionDraft()
  draft[.last] = text
  #expect(draft.errors == [.last: error])
}

@Test("an empty draft asks for at least one rule")
func emptyDraft() {
  let draft = RetentionDraft()
  #expect(draft.errors.isEmpty)
  #expect(throws: RetentionInputError.noRules) {
    try draft.policy()
  }
}
