import Foundation

public enum Schedule: Codable, Equatable, Hashable, Sendable {
  case manual
  case hourly
  case daily(hour: Int, minute: Int)

  private enum Kind: String, Codable {
    case manual
    case hourly
    case daily
  }

  private enum CodingKeys: String, CodingKey {
    case kind
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
    }
  }
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
      let components = DateComponents(hour: hour, minute: minute)
      guard let lastRun else {
        return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime, direction: .forward)
      }
      var slot = calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime, direction: .backward)
      let current = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: now)
      if current.hour == hour, current.minute == minute, current.second == 0, current.nanosecond == 0 {
        slot = now
      }
      if let slot, lastRun < slot {
        return slot
      }
      return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime, direction: .forward)
    }
  }

  public func isDue(lastRun: Date?, now: Date, calendar: Calendar) -> Bool {
    guard let nextRun = nextRun(after: lastRun, now: now, calendar: calendar) else { return false }
    return nextRun <= now
  }
}
