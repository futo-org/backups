import BackupsCore
import Foundation
import Testing

private var parisCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
  return calendar
}

private func parisDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
  parisCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Test("manual never schedules a run")
func manualNeverRuns() {
  let now = parisDate(2026, 6, 10, hour: 15, minute: 30)
  #expect(Schedule.manual.nextRun(after: nil, now: now, calendar: parisCalendar) == nil)
  #expect(Schedule.manual.nextRun(after: now.addingTimeInterval(-7200), now: now, calendar: parisCalendar) == nil)
  #expect(!Schedule.manual.isDue(lastRun: nil, now: now, calendar: parisCalendar))
  #expect(!Schedule.manual.isDue(lastRun: now.addingTimeInterval(-7200), now: now, calendar: parisCalendar))
}

@Test(
  "hourly nextRun and isDue",
  arguments: [
    (lastAgo: Double?.none, nextIn: 3600.0, due: false),
    (lastAgo: Double?.some(7200), nextIn: -3600.0, due: true),
    (lastAgo: Double?.some(600), nextIn: 3000.0, due: false),
  ])
func hourly(lastAgo: Double?, nextIn: Double, due: Bool) {
  let now = parisDate(2026, 6, 10, hour: 15, minute: 30)
  let lastRun = lastAgo.map { now.addingTimeInterval(-$0) }
  let expected = now.addingTimeInterval(nextIn)
  #expect(Schedule.hourly.nextRun(after: lastRun, now: now, calendar: parisCalendar) == expected)
  #expect(Schedule.hourly.isDue(lastRun: lastRun, now: now, calendar: parisCalendar) == due)
}

@Test(
  "daily nextRun and isDue",
  arguments: [
    (now: parisDate(2026, 6, 10, hour: 9), last: Date?.none, expected: parisDate(2026, 6, 10, hour: 12), due: false),
    (
      now: parisDate(2026, 6, 10, hour: 15, minute: 30), last: Date?.none, expected: parisDate(2026, 6, 11, hour: 12),
      due: false
    ),
    (
      now: parisDate(2026, 6, 10, hour: 15, minute: 30), last: Date?.some(parisDate(2026, 6, 10, hour: 8)),
      expected: parisDate(2026, 6, 10, hour: 12), due: true
    ),
    (
      now: parisDate(2026, 6, 10, hour: 15, minute: 30), last: Date?.some(parisDate(2026, 6, 10, hour: 12, minute: 5)),
      expected: parisDate(2026, 6, 11, hour: 12), due: false
    ),
    (
      now: parisDate(2026, 6, 10, hour: 12), last: Date?.some(parisDate(2026, 6, 9, hour: 12)),
      expected: parisDate(2026, 6, 10, hour: 12), due: true
    ),
  ])
func daily(now: Date, last: Date?, expected: Date, due: Bool) {
  let schedule = Schedule.daily(hour: 12, minute: 0)
  #expect(schedule.nextRun(after: last, now: now, calendar: parisCalendar) == expected)
  #expect(schedule.isDue(lastRun: last, now: now, calendar: parisCalendar) == due)
}

@Test("daily 02:30 on the Paris spring-forward day resolves once on that day")
func dailySpringForward() throws {
  let schedule = Schedule.daily(hour: 2, minute: 30)
  let calendar = parisCalendar
  let midnight = parisDate(2026, 3, 29)
  let gapStart = parisDate(2026, 3, 29, hour: 3)
  let lateMorning = parisDate(2026, 3, 29, hour: 4)

  let resolved = try #require(schedule.nextRun(after: nil, now: midnight, calendar: calendar))
  #expect(calendar.isDate(resolved, inSameDayAs: midnight))
  #expect(resolved >= gapStart)
  #expect(resolved <= lateMorning)

  #expect(schedule.isDue(lastRun: parisDate(2026, 3, 28, hour: 12), now: lateMorning, calendar: calendar))
  #expect(!schedule.isDue(lastRun: resolved, now: lateMorning, calendar: calendar))

  let following = try #require(schedule.nextRun(after: resolved, now: lateMorning, calendar: calendar))
  #expect(following > lateMorning)
  #expect(calendar.isDate(following, inSameDayAs: parisDate(2026, 3, 30, hour: 12)))
}

@Test(
  "Schedule Codable round trip",
  arguments: [
    Schedule.manual,
    Schedule.hourly,
    Schedule.daily(hour: 12, minute: 0),
    Schedule.daily(hour: 23, minute: 59),
  ])
func codableRoundTrip(schedule: Schedule) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let decoded = try JSONDecoder().decode(Schedule.self, from: encoder.encode(schedule))
  #expect(decoded == schedule)
}

@Test("daily encodes with kind and sorted keys")
func dailyExactJSON() throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  let data = try encoder.encode(Schedule.daily(hour: 12, minute: 0))
  #expect(String(data: data, encoding: .utf8) == #"{"hour":12,"kind":"daily","minute":0}"#)
}

@Test("manual and hourly encode with kind only")
func simpleExactJSON() throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  #expect(String(data: try encoder.encode(Schedule.manual), encoding: .utf8) == #"{"kind":"manual"}"#)
  #expect(String(data: try encoder.encode(Schedule.hourly), encoding: .utf8) == #"{"kind":"hourly"}"#)
}

@Test(
  "unknown kind fails to decode",
  arguments: [
    #"{"kind":"weekly"}"#,
    #"{"kind":"daily"}"#,
    "{}",
  ])
func unknownKindThrows(json: String) {
  #expect(throws: (any Error).self) {
    _ = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
  }
}
