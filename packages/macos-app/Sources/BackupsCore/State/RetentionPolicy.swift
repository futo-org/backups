import Foundation

public enum RetentionInputError: Error, Equatable, Sendable {
  case invalidDuration
  case zeroDuration
  case durationTooLong
  case notAPositiveNumber
  case numberTooLarge
  case noRules

  public var message: String {
    switch self {
    case .invalidDuration: return "Enter a duration like 60d or 1y6m: h hours, d days, m months, y years."
    case .zeroDuration: return "Enter a duration longer than zero."
    case .durationTooLong: return "Enter a shorter duration."
    case .notAPositiveNumber: return "Enter a whole number of 1 or more."
    case .numberTooLarge: return "Enter at most \(RetentionPolicy.maxKeepLast.formatted())."
    case .noRules: return "Fill in at least one rule. To keep all snapshots, choose Never."
    }
  }
}

public struct RetentionDuration: Equatable, Hashable, Sendable {
  public static let maxComponent = 9999

  public var years: Int
  public var months: Int
  public var days: Int
  public var hours: Int

  public init(years: Int = 0, months: Int = 0, days: Int = 0, hours: Int = 0) {
    self.years = years
    self.months = months
    self.days = days
    self.hours = hours
  }

  public init(parsing input: String) throws(RetentionInputError) {
    let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw .invalidDuration }
    var values: [Character: Int] = [:]
    var digits = ""
    for character in text {
      if character.isASCII && character.isNumber {
        digits.append(character)
        continue
      }
      guard !digits.isEmpty, "ymdh".contains(character), values[character] == nil else { throw .invalidDuration }
      guard digits.count <= 9, let value = Int(digits), value <= Self.maxComponent else { throw .durationTooLong }
      values[character] = value
      digits = ""
    }
    guard digits.isEmpty else { throw .invalidDuration }
    self.init(years: values["y"] ?? 0, months: values["m"] ?? 0, days: values["d"] ?? 0, hours: values["h"] ?? 0)
    guard !isZero else { throw .zeroDuration }
  }

  public var isZero: Bool { years == 0 && months == 0 && days == 0 && hours == 0 }

  public var text: String {
    let parts = [(years, "y"), (months, "m"), (days, "d"), (hours, "h")].filter { $0.0 > 0 }
    return parts.map { "\($0.0)\($0.1)" }.joined()
  }

  public var description: String {
    let parts = [(years, "year"), (months, "month"), (days, "day"), (hours, "hour")]
      .filter { $0.0 > 0 }
      .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
    guard let last = parts.last else { return "0 hours" }
    return parts.count == 1 ? last : parts.dropLast().joined(separator: ", ") + " and " + last
  }

  public func surelyCovers(_ other: RetentionDuration) -> Bool {
    let dominates =
      years >= other.years && months >= other.months && days >= other.days && hours >= other.hours
    let coversCalendarDays = hours >= other.hours && fewestCalendarDays >= other.mostCalendarDays
    return dominates || coversCalendarDays || fewestElapsedHours >= other.mostElapsedHours
  }

  private var fewestCalendarDays: Int { years * 365 + months * 28 + days }
  private var mostCalendarDays: Int { years * 366 + months * 31 + days }

  // restic steps calendar units back on the wall clock (Go's AddDate), so DST and time zone changes stretch or
  // shrink them in elapsed time; hours are always elapsed time, so only compare the two with a day of slack.
  private var calendarSlackHours: Int { fewestCalendarDays > 0 ? 24 : 0 }
  private var fewestElapsedHours: Int { fewestCalendarDays * 24 - calendarSlackHours + hours }
  private var mostElapsedHours: Int { mostCalendarDays * 24 + calendarSlackHours + hours }
}

public enum RetentionField: String, CaseIterable, Identifiable, Sendable {
  case last
  case within
  case hourly
  case daily
  case weekly
  case monthly
  case yearly

  public var id: String { rawValue }

  public var flag: String {
    switch self {
    case .last: "--keep-last"
    case .within: "--keep-within"
    case .hourly: "--keep-within-hourly"
    case .daily: "--keep-within-daily"
    case .weekly: "--keep-within-weekly"
    case .monthly: "--keep-within-monthly"
    case .yearly: "--keep-within-yearly"
    }
  }

  public var title: String {
    switch self {
    case .last: "Keep the latest"
    case .within: "Keep all snapshots within"
    case .hourly: "Keep hourly snapshots within"
    case .daily: "Keep daily snapshots within"
    case .weekly: "Keep weekly snapshots within"
    case .monthly: "Keep monthly snapshots within"
    case .yearly: "Keep yearly snapshots within"
    }
  }

  public var detail: String {
    switch self {
    case .last: "Number of backups, however old."
    case .within: "Every snapshot newer than this."
    case .hourly: "The last snapshot of each hour."
    case .daily: "The last snapshot of each day."
    case .weekly: "The last snapshot of each week."
    case .monthly: "The last snapshot of each month."
    case .yearly: "The last snapshot of each year."
    }
  }

  public var placeholder: String {
    switch self {
    case .last: "2"
    case .within: "60d"
    case .hourly: "2d"
    case .daily: "1m"
    case .weekly: "6m"
    case .monthly: "2y"
    case .yearly: "10y"
    }
  }

  fileprivate var period: String? {
    switch self {
    case .last, .within: nil
    case .hourly: "hourly"
    case .daily: "daily"
    case .weekly: "weekly"
    case .monthly: "monthly"
    case .yearly: "yearly"
    }
  }

  fileprivate var durationKeyPath: WritableKeyPath<RetentionPolicy, String?>? {
    switch self {
    case .last: nil
    case .within: \.keepWithin
    case .hourly: \.keepWithinHourly
    case .daily: \.keepWithinDaily
    case .weekly: \.keepWithinWeekly
    case .monthly: \.keepWithinMonthly
    case .yearly: \.keepWithinYearly
    }
  }

  fileprivate static let durations = allCases.filter { $0 != .last }
}

public struct RetentionPolicy: Codable, Equatable, Hashable, Sendable {
  public static let maxKeepLast = 100_000

  public var keepLast: Int?
  public var keepWithin: String?
  public var keepWithinHourly: String?
  public var keepWithinDaily: String?
  public var keepWithinWeekly: String?
  public var keepWithinMonthly: String?
  public var keepWithinYearly: String?

  public init(
    keepLast: Int? = nil, keepWithin: String? = nil, keepWithinHourly: String? = nil, keepWithinDaily: String? = nil,
    keepWithinWeekly: String? = nil, keepWithinMonthly: String? = nil, keepWithinYearly: String? = nil
  ) {
    self.keepLast = keepLast
    self.keepWithin = keepWithin
    self.keepWithinHourly = keepWithinHourly
    self.keepWithinDaily = keepWithinDaily
    self.keepWithinWeekly = keepWithinWeekly
    self.keepWithinMonthly = keepWithinMonthly
    self.keepWithinYearly = keepWithinYearly
  }

  public subscript(field: RetentionField) -> String? {
    guard let keyPath = field.durationKeyPath else { return keepLast.map(String.init) }
    return self[keyPath: keyPath]
  }

  public func validated() throws(RetentionInputError) -> ValidRetentionPolicy {
    var rules: [ValidRetentionPolicy.Rule] = []
    if let keepLast {
      guard keepLast > 0 else { throw .notAPositiveNumber }
      guard keepLast <= Self.maxKeepLast else { throw .numberTooLarge }
      rules.append(.init(field: .last, value: .count(keepLast)))
    }
    for field in RetentionField.durations {
      if let text = self[field] {
        rules.append(.init(field: field, value: .duration(try RetentionDuration(parsing: text))))
      }
    }
    guard !rules.isEmpty else { throw .noRules }
    return ValidRetentionPolicy(rules: rules)
  }
}

public struct ValidRetentionPolicy: Equatable, Sendable {
  public enum Value: Equatable, Sendable {
    case count(Int)
    case duration(RetentionDuration)

    var text: String {
      switch self {
      case .count(let count): String(count)
      case .duration(let duration): duration.text
      }
    }
  }

  public struct Rule: Equatable, Sendable {
    public var field: RetentionField
    public var value: Value
  }

  public let rules: [Rule]

  public var policy: RetentionPolicy {
    var policy = RetentionPolicy()
    for rule in rules {
      policy.set(rule)
    }
    return policy
  }

  public var resticArguments: [String] {
    rules.flatMap { [$0.field.flag, $0.value.text] }
  }

  public var telemetryValue: String {
    rules.map { "\($0.field.flag.dropFirst(2)) \($0.value.text)" }.joined(separator: ", ")
  }

  public var summary: String {
    if let count = onlyKeepLast {
      return count == 1 ? "Keep the latest backup" : "Keep the latest \(count) backups"
    }
    if let duration = onlyKeepWithin {
      return "Keep the last \(duration.description)"
    }
    let clauses = rules.map { rule in
      switch (rule.field.period, rule.value) {
      case (_, .count(let count)): count == 1 ? "latest backup" : "latest \(count) backups"
      case (nil, .duration(let duration)): "all for \(duration.description)"
      case (let period?, .duration(let duration)): "\(period) for \(duration.description)"
      }
    }
    let sentence = clauses.joined(separator: ", ")
    return sentence.prefix(1).uppercased() + sentence.dropFirst()
  }

  var onlyKeepWithin: RetentionDuration? {
    guard rules.count == 1, let rule = rules.first, rule.field == .within, case .duration(let duration) = rule.value
    else { return nil }
    return duration
  }

  var onlyKeepLast: Int? {
    guard rules.count == 1, case .count(let count) = rules.first?.value else { return nil }
    return count
  }

  public func keepsEverythingKept(by other: ValidRetentionPolicy) -> Bool {
    other.rules.allSatisfy { rule in
      switch rule.value {
      case .count(let count):
        return keepLast.map { $0 >= count } ?? false
      case .duration(let duration):
        return [rule.field, .within].contains { field in
          self.duration(for: field).map { $0.surelyCovers(duration) } ?? false
        }
      }
    }
  }

  private var keepLast: Int? {
    rules.lazy.compactMap { rule -> Int? in
      if case .count(let count) = rule.value { return count }
      return nil
    }.first
  }

  private func duration(for field: RetentionField) -> RetentionDuration? {
    rules.lazy.compactMap { rule -> RetentionDuration? in
      if rule.field == field, case .duration(let duration) = rule.value { return duration }
      return nil
    }.first
  }
}

extension RetentionPolicy {
  fileprivate mutating func set(_ rule: ValidRetentionPolicy.Rule) {
    switch rule.value {
    case .count(let count): keepLast = count
    case .duration(let duration): rule.field.durationKeyPath.map { self[keyPath: $0] = duration.text }
    }
  }
}

public enum SnapshotRetention: Codable, Equatable, Hashable, Sendable {
  case keepAll
  case policy(RetentionPolicy)

  public static let standard = SnapshotRetention.policy(RetentionPolicy(keepWithin: "60d"))

  private enum CodingKeys: String, CodingKey {
    case keepAll
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if try container.decodeIfPresent(Bool.self, forKey: .keepAll) == true {
      self = .keepAll
    } else {
      self = .policy(try RetentionPolicy(from: decoder))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .keepAll:
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(true, forKey: .keepAll)
    case .policy(let policy):
      try policy.encode(to: encoder)
    }
  }

  public var prunablePolicy: ValidRetentionPolicy? {
    guard case .policy(let policy) = self else { return nil }
    return try? policy.validated()
  }

  public var summary: String {
    switch self {
    case .keepAll: return "Keep all snapshots"
    case .policy(let policy):
      return (try? policy.validated())?.summary ?? "Keep all snapshots until you correct the retention setting"
    }
  }

  public var telemetryValue: String {
    switch self {
    case .keepAll: return "keep-all"
    case .policy(let policy): return (try? policy.validated())?.telemetryValue ?? "invalid"
    }
  }

  public func mayDeleteMore(than current: SnapshotRetention) -> Bool {
    guard let proposed = prunablePolicy else { return false }
    guard let existing = current.prunablePolicy else { return true }
    return !proposed.keepsEverythingKept(by: existing)
  }

  public func mayDeleteResumedSnapshots(hostnames: [String]?, host: String) -> Bool {
    guard mayDeleteMore(than: .keepAll) else { return false }
    return hostnames?.contains(host) ?? true
  }
}

public enum RetentionPreset: String, CaseIterable, Identifiable, Sendable {
  case days15
  case days30
  case days60
  case days90
  case latestTwo
  case never

  public static let standard = RetentionPreset.days60

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .days15: "After 15 days"
    case .days30: "After 30 days"
    case .days60: "After 60 days"
    case .days90: "After 90 days"
    case .latestTwo: "Keep latest two backups"
    case .never: "Never (keep all backups)"
    }
  }

  public var keepLabel: String {
    switch self {
    case .days15: "15 days"
    case .days30: "30 days"
    case .days60: "60 days"
    case .days90: "90 days"
    case .latestTwo: "Latest two backups"
    case .never: "Forever"
    }
  }

  public var retention: SnapshotRetention {
    switch self {
    case .days15: .policy(RetentionPolicy(keepWithin: "15d"))
    case .days30: .policy(RetentionPolicy(keepWithin: "30d"))
    case .days60: .policy(RetentionPolicy(keepWithin: "60d"))
    case .days90: .policy(RetentionPolicy(keepWithin: "90d"))
    case .latestTwo: .policy(RetentionPolicy(keepLast: 2))
    case .never: .keepAll
    }
  }

  public init?(_ retention: SnapshotRetention) {
    guard let preset = Self.allCases.first(where: { $0.retention == retention }) else { return nil }
    self = preset
  }
}

public struct RetentionDraft: Equatable, Sendable {
  public var values: [RetentionField: String]

  public init(_ policy: RetentionPolicy = RetentionPolicy()) {
    values = Dictionary(uniqueKeysWithValues: RetentionField.allCases.map { ($0, policy[$0] ?? "") })
  }

  public subscript(field: RetentionField) -> String {
    get { values[field] ?? "" }
    set { values[field] = newValue }
  }

  public var errors: [RetentionField: RetentionInputError] {
    var errors: [RetentionField: RetentionInputError] = [:]
    for field in RetentionField.allCases {
      do {
        _ = try value(field)
      } catch {
        errors[field] = error
      }
    }
    return errors
  }

  public func policy() throws(RetentionInputError) -> RetentionPolicy {
    var policy = RetentionPolicy()
    for field in RetentionField.allCases {
      if let value = try value(field) {
        policy.set(ValidRetentionPolicy.Rule(field: field, value: value))
      }
    }
    return try policy.validated().policy
  }

  private func value(_ field: RetentionField) throws(RetentionInputError) -> ValidRetentionPolicy.Value? {
    let text = self[field].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    guard field == .last else { return .duration(try RetentionDuration(parsing: text)) }
    guard text.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw .notAPositiveNumber }
    guard text.count <= 9, let count = Int(text) else { throw .numberTooLarge }
    guard count > 0 else { throw .notAPositiveNumber }
    guard count <= RetentionPolicy.maxKeepLast else { throw .numberTooLarge }
    return .count(count)
  }
}
