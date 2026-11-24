import Foundation

public enum Schedule: Codable, Equatable, Hashable, Sendable {
  case manual
  case hourly
  case daily(hour: Int, minute: Int)
  case weekly(weekday: Int, hour: Int, minute: Int)

  private enum Kind: String, Codable {
    case manual
    case hourly
    case daily
    case weekly
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case weekday
    case hour
    case minute
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .manual:
      self = .manual
    case .hourly:
      self = .hourly
    case .daily:
      self = .daily(
        hour: try container.decode(Int.self, forKey: .hour),
        minute: try container.decode(Int.self, forKey: .minute)
      )
    case .weekly:
      let weekday = try container.decode(Int.self, forKey: .weekday)
      guard Self.weekdayRange.contains(weekday) else {
        throw DecodingError.dataCorruptedError(
          forKey: .weekday, in: container, debugDescription: "weekday must be 1 (Sunday) through 7 (Saturday)")
      }
      self = .weekly(
        weekday: weekday,
        hour: try container.decode(Int.self, forKey: .hour),
        minute: try container.decode(Int.self, forKey: .minute)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .manual:
      try container.encode(Kind.manual, forKey: .kind)
    case .hourly:
      try container.encode(Kind.hourly, forKey: .kind)
    case .daily(let hour, let minute):
      try container.encode(Kind.daily, forKey: .kind)
      try container.encode(hour, forKey: .hour)
      try container.encode(minute, forKey: .minute)
    case .weekly(let weekday, let hour, let minute):
      try container.encode(Kind.weekly, forKey: .kind)
      try container.encode(weekday, forKey: .weekday)
      try container.encode(hour, forKey: .hour)
      try container.encode(minute, forKey: .minute)
    }
  }

  private static let weekdayRange = 1...7
}

extension Schedule {
  public func nextRun(after lastRun: Date?, now: Date, calendar: Calendar) -> Date? {
    switch self {
    case .manual:
      return nil
    case .hourly:
      guard let lastRun else { return now.addingTimeInterval(3600) }
      return lastRun.addingTimeInterval(3600)
    case .daily(let hour, let minute):
      return Self.slotRun(weekday: nil, hour: hour, minute: minute, after: lastRun, now: now, calendar: calendar)
    case .weekly(let weekday, let hour, let minute):
      return Self.slotRun(weekday: weekday, hour: hour, minute: minute, after: lastRun, now: now, calendar: calendar)
    }
  }

  public func isDue(lastRun: Date?, now: Date, calendar: Calendar) -> Bool {
    guard let nextRun = nextRun(after: lastRun, now: now, calendar: calendar) else { return false }
    return nextRun <= now
  }

  public static func weekdays(calendar: Calendar) -> [Int] {
    weekdayRange.map { ($0 - 1 + calendar.firstWeekday - 1) % 7 + 1 }
  }

  public static func weekdayName(_ weekday: Int, calendar: Calendar) -> String {
    let symbols = calendar.weekdaySymbols
    guard weekdayRange.contains(weekday), symbols.count == weekdayRange.count else { return "" }
    return symbols[weekday - 1]
  }

  private static func slotRun(
    weekday: Int?, hour: Int, minute: Int, after lastRun: Date?, now: Date, calendar: Calendar
  ) -> Date? {
    let slot = { (dayOffset: Int) in
      Self.slot(dayOffset: dayOffset, from: now, weekday: weekday, hour: hour, minute: minute, calendar: calendar)
    }
    if let lastRun, let latest = (-7...0).reversed().lazy.compactMap(slot).first(where: { $0 <= now }),
      lastRun < latest
    {
      return latest
    }
    return (0...7).lazy.compactMap(slot).first { $0 > now }
  }

  private static func slot(
    dayOffset: Int, from now: Date, weekday: Int?, hour: Int, minute: Int, calendar: Calendar
  ) -> Date? {
    guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else {
      return nil
    }
    if let weekday, calendar.component(.weekday, from: day) != weekday { return nil }
    return calendar.nextDate(
      after: day.addingTimeInterval(-1), matching: DateComponents(hour: hour, minute: minute),
      matchingPolicy: .nextTime, direction: .forward)
  }
}
