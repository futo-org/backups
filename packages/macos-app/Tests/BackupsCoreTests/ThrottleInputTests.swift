import BackupsCore
import Testing

@Test(
  "upload limit parses kilobytes into bytes per second",
  arguments: [
    ("", 0),
    ("   ", 0),
    ("0", 0),
    ("1", 1024),
    (" 512 ", 524_288),
    ("10000000", 10_240_000_000),
  ])
func uploadLimitParses(text: String, bytesPerSecond: Int) throws {
  #expect(try UploadLimit.bytesPerSecond(parsing: text) == bytesPerSecond)
}

@Test(
  "upload limit rejects input that isn't a whole number",
  arguments: ["-5", "1.5", "abc", "12k", "+3", "1 000", "٣"])
func uploadLimitRejectsNonIntegers(text: String) {
  #expect(throws: UploadLimitError.notAWholeNumber) {
    try UploadLimit.bytesPerSecond(parsing: text)
  }
}

@Test(
  "upload limit rejects values above the maximum without overflowing",
  arguments: ["10000001", "9223372036854775807", "99999999999999999999999999"])
func uploadLimitRejectsHugeValues(text: String) {
  #expect(throws: UploadLimitError.tooLarge) {
    try UploadLimit.bytesPerSecond(parsing: text)
  }
}

@Test("upload limit text shows kilobytes and empty for unlimited")
func uploadLimitText() {
  #expect(UploadLimit.text(bytesPerSecond: 0) == "")
  #expect(UploadLimit.text(bytesPerSecond: 524_288) == "512")
}

@Test(
  "clock time parses valid HH:MM only",
  arguments: [
    ("07:05", ClockTime?.some(ClockTime(hour: 7, minute: 5))),
    ("23:59", ClockTime(hour: 23, minute: 59)),
    ("24:00", nil),
    ("12:60", nil),
    ("12", nil),
    ("ab:cd", nil),
  ])
func clockTimeParses(text: String, expected: ClockTime?) {
  #expect(ClockTime(parsing: text) == expected)
}

@Test("quiet hours round trip through their text")
func quietHoursRoundTrip() throws {
  let quietHours = try QuietHours(start: ClockTime(hour: 22, minute: 0), end: ClockTime(hour: 7, minute: 30))
  #expect(quietHours.text == "22:00-07:30")
  #expect(QuietHours(parsing: "22:00-07:30") == quietHours)
}

@Test("quiet hours with the same start and end are rejected")
func quietHoursRejectsEqualEnds() {
  #expect(throws: QuietHoursError.sameStartAndEnd) {
    try QuietHours(start: ClockTime(hour: 9, minute: 0), end: ClockTime(hour: 9, minute: 0))
  }
  #expect(QuietHours(parsing: "09:00-09:00") == nil)
}

@Test("quiet hours parsing rejects malformed text", arguments: ["", "22:00", "22:00-", "22:00-25:00", "x-y"])
func quietHoursRejectsMalformed(text: String) {
  #expect(QuietHours(parsing: text) == nil)
}
