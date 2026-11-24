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

private var torontoCalendar: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/Toronto")!
  return calendar
}

private func torontoDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0) -> Date {
  torontoCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

private func utc(_ text: String) -> Date {
  ISO8601DateFormatter().date(from: text)!
}

private let monday = 2
private let sunday = 1

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

@Test("daily in the repeated Toronto fall-back hour runs once, at the first 01:30")
func dailyFallBackRunsOnce() throws {
  let schedule = Schedule.daily(hour: 1, minute: 30)
  let calendar = torontoCalendar
  let firstPass = utc("2026-11-01T05:30:00Z")
  #expect(schedule.nextRun(after: nil, now: torontoDate(2026, 10, 31, hour: 22), calendar: calendar) == firstPass)
  let ranAt = firstPass.addingTimeInterval(20)
  for now in [utc("2026-11-01T05:45:00Z"), utc("2026-11-01T06:30:00Z"), utc("2026-11-01T06:45:00Z")] {
    #expect(!schedule.isDue(lastRun: ranAt, now: now, calendar: calendar))
    #expect(schedule.nextRun(after: ranAt, now: now, calendar: calendar) == utc("2026-11-02T06:30:00Z"))
  }
}

@Test(
  "weekly nextRun and isDue",
  arguments: [
    (now: torontoDate(2026, 6, 8, hour: 9), last: Date?.none, expected: torontoDate(2026, 6, 8, hour: 12), due: false),
    (
      now: torontoDate(2026, 6, 10, hour: 15, minute: 30), last: Date?.none,
      expected: torontoDate(2026, 6, 15, hour: 12), due: false
    ),
    (
      now: torontoDate(2026, 6, 10, hour: 15, minute: 30), last: Date?.some(torontoDate(2026, 6, 7, hour: 20)),
      expected: torontoDate(2026, 6, 8, hour: 12), due: true
    ),
    (
      now: torontoDate(2026, 6, 10, hour: 15, minute: 30),
      last: Date?.some(torontoDate(2026, 6, 8, hour: 12, minute: 5)),
      expected: torontoDate(2026, 6, 15, hour: 12), due: false
    ),
    (
      now: torontoDate(2026, 6, 8, hour: 12), last: Date?.some(torontoDate(2026, 6, 1, hour: 12)),
      expected: torontoDate(2026, 6, 8, hour: 12), due: true
    ),
    (
      now: torontoDate(2026, 6, 15, hour: 11), last: Date?.some(torontoDate(2026, 6, 1, hour: 12)),
      expected: torontoDate(2026, 6, 8, hour: 12), due: true
    ),
    (
      now: torontoDate(2026, 6, 14, hour: 23, minute: 59), last: Date?.some(torontoDate(2026, 6, 10, hour: 9)),
      expected: torontoDate(2026, 6, 15, hour: 12), due: false
    ),
  ])
func weekly(now: Date, last: Date?, expected: Date, due: Bool) {
  let schedule = Schedule.weekly(weekday: monday, hour: 12, minute: 0)
  #expect(schedule.nextRun(after: last, now: now, calendar: torontoCalendar) == expected)
  #expect(schedule.isDue(lastRun: last, now: now, calendar: torontoCalendar) == due)
}

@Test("weekly keeps its wall-clock time across the Toronto spring-forward and fall-back")
func weeklyAcrossDSTKeepsWallClock() {
  let schedule = Schedule.weekly(weekday: sunday, hour: 12, minute: 0)
  let calendar = torontoCalendar
  let springNext = schedule.nextRun(
    after: torontoDate(2026, 3, 1, hour: 12), now: torontoDate(2026, 3, 7, hour: 12), calendar: calendar)
  #expect(springNext == utc("2026-03-08T16:00:00Z"))
  let fallNext = schedule.nextRun(
    after: torontoDate(2026, 10, 25, hour: 12), now: torontoDate(2026, 10, 31, hour: 12), calendar: calendar)
  #expect(fallNext == utc("2026-11-01T17:00:00Z"))
  #expect(
    schedule.isDue(
      lastRun: torontoDate(2026, 10, 25, hour: 12), now: utc("2026-11-01T18:00:00Z"), calendar: calendar))
}

@Test("weekly 02:30 on the Toronto spring-forward Sunday resolves once, at 03:00 that day")
func weeklySpringForwardGap() throws {
  let schedule = Schedule.weekly(weekday: sunday, hour: 2, minute: 30)
  let calendar = torontoCalendar
  let resolved = try #require(
    schedule.nextRun(after: nil, now: torontoDate(2026, 3, 7, hour: 12), calendar: calendar))
  #expect(resolved == utc("2026-03-08T07:00:00Z"))
  let later = torontoDate(2026, 3, 8, hour: 9)
  #expect(schedule.isDue(lastRun: torontoDate(2026, 3, 1, hour: 12), now: later, calendar: calendar))
  #expect(!schedule.isDue(lastRun: resolved, now: later, calendar: calendar))
  #expect(
    schedule.nextRun(after: resolved, now: later, calendar: calendar) == torontoDate(2026, 3, 15, hour: 2, minute: 30))
}

@Test("weekly 01:30 on the Toronto fall-back Sunday runs once, at the first 01:30")
func weeklyFallBackRunsOnce() {
  let schedule = Schedule.weekly(weekday: sunday, hour: 1, minute: 30)
  let calendar = torontoCalendar
  let firstPass = utc("2026-11-01T05:30:00Z")
  #expect(schedule.nextRun(after: nil, now: torontoDate(2026, 10, 31, hour: 12), calendar: calendar) == firstPass)
  let ranAt = firstPass.addingTimeInterval(20)
  for now in [utc("2026-11-01T05:45:00Z"), utc("2026-11-01T06:30:00Z"), utc("2026-11-01T06:45:00Z")] {
    #expect(!schedule.isDue(lastRun: ranAt, now: now, calendar: calendar))
    #expect(schedule.nextRun(after: ranAt, now: now, calendar: calendar) == utc("2026-11-08T06:30:00Z"))
  }
}

@Test("weekdays follow the locale's first day of the week and names")
func weekdaysFollowLocale() {
  var unitedStates = Calendar(identifier: .gregorian)
  unitedStates.locale = Locale(identifier: "en_US")
  #expect(Schedule.weekdays(calendar: unitedStates) == [1, 2, 3, 4, 5, 6, 7])
  #expect(Schedule.weekdayName(monday, calendar: unitedStates) == "Monday")
  var france = Calendar(identifier: .gregorian)
  france.locale = Locale(identifier: "fr_FR")
  #expect(Schedule.weekdays(calendar: france) == [2, 3, 4, 5, 6, 7, 1])
  #expect(Schedule.weekdayName(monday, calendar: france) == "lundi")
  #expect(Schedule.weekdayName(0, calendar: france) == "")
  #expect(Schedule.weekdayName(8, calendar: france) == "")
}

@Test(
  "Schedule Codable round trip",
  arguments: [
    Schedule.manual,
    Schedule.hourly,
    Schedule.daily(hour: 12, minute: 0),
    Schedule.daily(hour: 23, minute: 59),
    Schedule.weekly(weekday: 2, hour: 12, minute: 0),
    Schedule.weekly(weekday: 7, hour: 0, minute: 5),
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

@Test("weekly encodes with kind, weekday and time")
func weeklyExactJSON() throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .sortedKeys
  let data = try encoder.encode(Schedule.weekly(weekday: 2, hour: 12, minute: 0))
  #expect(String(data: data, encoding: .utf8) == #"{"hour":12,"kind":"weekly","minute":0,"weekday":2}"#)
}

@Test(
  "existing config values decode unchanged",
  arguments: [
    (#"{"kind":"manual"}"#, Schedule.manual),
    (#"{"kind":"hourly"}"#, Schedule.hourly),
    (#"{"hour":12,"kind":"daily","minute":0}"#, Schedule.daily(hour: 12, minute: 0)),
  ])
func existingValuesDecode(json: String, expected: Schedule) throws {
  #expect(try JSONDecoder().decode(Schedule.self, from: Data(json.utf8)) == expected)
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
    #"{"kind":"weekly","hour":12,"minute":0}"#,
    #"{"kind":"weekly","weekday":0,"hour":12,"minute":0}"#,
    #"{"kind":"weekly","weekday":8,"hour":12,"minute":0}"#,
    #"{"kind":"monthly"}"#,
    #"{"kind":"daily"}"#,
    "{}",
  ])
func unknownKindThrows(json: String) {
  #expect(throws: (any Error).self) {
    _ = try JSONDecoder().decode(Schedule.self, from: Data(json.utf8))
  }
}
