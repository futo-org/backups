import Foundation

public enum UploadLimitError: Error, Equatable, Sendable {
  case notAWholeNumber
  case tooLarge

  public var message: String {
    switch self {
    case .notAWholeNumber: return "Enter a whole number of KB/s, or leave it empty for no limit."
    case .tooLarge: return "Enter at most \(UploadLimit.maxKilobytesPerSecond.formatted()) KB/s."
    }
  }
}

public enum UploadLimit {
  public static let maxKilobytesPerSecond = 10_000_000

  public static func bytesPerSecond(parsing text: String) throws(UploadLimitError) -> Int {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return 0 }
    guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw .notAWholeNumber }
    guard let kilobytes = Int(trimmed), kilobytes <= maxKilobytesPerSecond else { throw .tooLarge }
    return kilobytes * 1024
  }

  public static func text(bytesPerSecond: Int) -> String {
    bytesPerSecond > 0 ? String(bytesPerSecond / 1024) : ""
  }
}

public struct ClockTime: Equatable, Hashable, Sendable {
  public var hour: Int
  public var minute: Int

  public init(hour: Int, minute: Int) {
    self.hour = hour
    self.minute = minute
  }

  public init?(parsing text: some StringProtocol) {
    let parts = text.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
      (0..<24).contains(hour), (0..<60).contains(minute)
    else { return nil }
    self.init(hour: hour, minute: minute)
  }

  public var text: String { String(format: "%02d:%02d", hour, minute) }
}

public enum QuietHoursError: Error, Equatable, Sendable {
  case sameStartAndEnd

  public var message: String {
    switch self {
    case .sameStartAndEnd: return "Choose different start and end times."
    }
  }
}

public struct QuietHours: Equatable, Sendable {
  public var start: ClockTime
  public var end: ClockTime

  public init(start: ClockTime, end: ClockTime) throws(QuietHoursError) {
    guard start != end else { throw .sameStartAndEnd }
    self.start = start
    self.end = end
  }

  public init?(parsing text: String) {
    let parts = text.split(separator: "-", maxSplits: 1)
    guard parts.count == 2, let start = ClockTime(parsing: parts[0]), let end = ClockTime(parsing: parts[1]),
      let parsed = try? QuietHours(start: start, end: end)
    else { return nil }
    self = parsed
  }

  public var text: String { "\(start.text)-\(end.text)" }
}

extension Throttle {
  public func activeLimit(at date: Date, calendar: Calendar = .current) -> Int? {
    guard bytesPerSec > 0 else { return nil }
    let parts = quietHours.split(separator: "-", maxSplits: 1)
    guard parts.count == 2, let start = ClockTime(parsing: parts[0]), let end = ClockTime(parsing: parts[1])
    else { return bytesPerSec }
    let components = calendar.dateComponents([.hour, .minute], from: date)
    let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    let from = start.hour * 60 + start.minute
    let until = end.hour * 60 + end.minute
    let quiet: Bool
    if from == until {
      quiet = true
    } else if from < until {
      quiet = minute >= from && minute < until
    } else {
      quiet = minute >= from || minute < until
    }
    return quiet ? nil : bytesPerSec
  }
}
