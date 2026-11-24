import Foundation
import Testing

@testable import BackupsCore

private let base = ContinuousClock.now
private let window = Int(UploadSpeedMeter.window)

private func at(_ second: Double) -> ContinuousClock.Instant {
  base + .milliseconds(Int((second * 1000).rounded()))
}

private func feed(_ meter: inout UploadSpeedMeter, _ totals: [Int64], from start: Double = 0) -> [UploadSpeed] {
  totals.enumerated().map { index, total in meter.record(total, at: at(start + Double(index))) }
}

@Test func meterStartsIdleAndKeepsTheThrottle() {
  let throttle = Throttle(bytesPerSec: 4096, quietHours: "22:00-06:00")
  var meter = UploadSpeedMeter(throttle: throttle)
  #expect(meter.speed == UploadSpeed(throttle: throttle))
  let first = meter.record(0, at: at(0))
  #expect(!first.hasStarted)
  #expect(first.bytesPerSecond == 0)
  #expect(first.averageBytesPerSecond == 0)
  #expect(first.history == [UploadSpeed.Point(secondsAgo: 0, bytesPerSecond: 0)])
  #expect(first.throttle == throttle)
}

@Test func steadyUploadReadsAsItsRate() throws {
  var meter = UploadSpeedMeter()
  let speeds = feed(&meter, (0...10).map { Int64($0) * 1_000_000 })
  let last = try #require(speeds.last)
  #expect(abs(last.bytesPerSecond - 1_000_000) < 1)
  #expect(abs(last.averageBytesPerSecond - 1_000_000) < 1)
  #expect(abs(last.peakBytesPerSecond - 1_000_000) < 1)
  #expect(last.uploadedBytes == 10_000_000)
  #expect(last.hasStarted)
}

@Test func aPackBurstFadesOutWithoutDroppingToZeroInsideTheWindow() {
  var meter = UploadSpeedMeter()
  _ = feed(&meter, Array(repeating: 0, count: 6))
  let burst: Int64 = 16 << 20
  let speeds = feed(&meter, Array(repeating: burst, count: window + 2), from: 6)
  let fading = speeds.prefix(window).map(\.bytesPerSecond)
  #expect(fading.allSatisfy { $0 > 0 })
  #expect(zip(fading, fading.dropFirst()).allSatisfy { $0 > $1 })
  #expect(speeds[window].bytesPerSecond == 0)
  #expect(speeds.last?.bytesPerSecond == 0)
  #expect(speeds.last?.uploadedBytes == burst)
}

@Test func periodicPackBurstsNeverReadAsZero() {
  var meter = UploadSpeedMeter()
  var total: Int64 = 0
  var speeds: [UploadSpeed] = []
  for second in 0..<30 {
    if second > 0, second.isMultiple(of: 3) {
      total += 16 << 20
    }
    speeds.append(meter.record(total, at: at(Double(second))))
  }
  #expect(speeds.dropFirst(4).allSatisfy { $0.bytesPerSecond > 0 })
}

@Test func aStallDecaysToExactlyZeroAfterTheWindow() {
  var meter = UploadSpeedMeter()
  _ = feed(&meter, (0...10).map { Int64($0) * 2_000_000 })
  let stalled = feed(&meter, Array(repeating: 20_000_000, count: window + 2), from: 11)
  let speeds = stalled.map(\.bytesPerSecond)
  #expect(zip(speeds, speeds.dropFirst()).allSatisfy { $0 >= $1 })
  #expect(speeds[window - 2] > 0)
  #expect(speeds[window - 1] == 0)
  #expect(stalled.last?.peakBytesPerSecond ?? 0 >= 1_999_999)
}

@Test func aCounterResetKeepsCountingFromThePreviousTotal() {
  var meter = UploadSpeedMeter()
  _ = meter.record(0, at: at(0))
  _ = meter.record(1_000_000, at: at(1))
  let afterReset = meter.record(200_000, at: at(2))
  #expect(afterReset.uploadedBytes == 1_200_000)
  #expect(afterReset.bytesPerSecond > 0)
  let next = meter.record(700_000, at: at(3))
  #expect(next.uploadedBytes == 1_700_000)
}

@Test func samplesThatDoNotMoveForwardInTimeAreIgnored() {
  var meter = UploadSpeedMeter()
  _ = meter.record(0, at: at(0))
  let recorded = meter.record(1_000_000, at: at(1))
  #expect(meter.record(9_000_000, at: at(1)) == recorded)
  #expect(meter.record(9_000_000, at: at(0.5)) == recorded)
}

@Test func aLongGapBetweenSamplesSpreadsItsBytesOverTheGap() {
  var meter = UploadSpeedMeter()
  _ = meter.record(0, at: at(0))
  let speed = meter.record(10_000_000, at: at(10))
  #expect(abs(speed.bytesPerSecond - 1_000_000) < 1)
}

@Test func theAverageStartsWhenUploadingStarts() {
  var meter = UploadSpeedMeter()
  _ = feed(&meter, Array(repeating: 0, count: 11))
  let speeds = feed(&meter, [3_000_000, 6_000_000], from: 11)
  #expect(abs(speeds[0].averageBytesPerSecond - 3_000_000) < 1)
  #expect(abs(speeds[1].averageBytesPerSecond - 3_000_000) < 1)
}

@Test func historyKeepsTheLastTwoMinutesOldestFirst() throws {
  var meter = UploadSpeedMeter()
  let speeds = feed(&meter, (0..<300).map { Int64($0) * 1000 })
  let history = try #require(speeds.last?.history)
  #expect(history.count == 121)
  #expect(history.first?.secondsAgo == UploadSpeed.historySeconds)
  #expect(history.last?.secondsAgo == 0)
  #expect(zip(history, history.dropFirst()).allSatisfy { $0.secondsAgo > $1.secondsAgo })
}

@Test(
  "the chart ceiling rounds up with headroom and never zooms below a floor",
  arguments: [
    (0.0, 100_000.0),
    (50_000, 100_000),
    (1_000_000, 2_000_000),
    (2_000_000, 2_500_000),
    (4_000_000, 5_000_000),
    (8_500_000, 10_000_000),
    (100_000_000, 200_000_000),
  ])
func chartCeiling(highest: Double, ceiling: Double) {
  #expect(UploadSpeed.chartCeiling(for: highest) == ceiling)
  #expect(UploadSpeed.chartCeiling(for: highest) >= highest * 1.15)
}

@Test func chartCeilingFollowsTheHistoryNotThePeak() {
  let speed = UploadSpeed(
    peakBytesPerSecond: 90_000_000,
    history: [UploadSpeed.Point(secondsAgo: 1, bytesPerSecond: 1_000_000)])
  #expect(speed.chartCeiling == 2_000_000)
}

@Test func rateTextUsesFileByteCountsPerSecond() {
  #expect(UploadSpeed.rateText(12_400_000).hasPrefix("12"))
  #expect(UploadSpeed.rateText(12_400_000).hasSuffix("MB/s"))
  #expect(UploadSpeed.rateText(0).hasPrefix("0"))
  #expect(UploadSpeed.rateText(-5).hasPrefix("0"))
}

@Test func accessibilitySummaryNamesCurrentAverageAndPeak() {
  #expect(UploadSpeed().accessibilitySummary == "Preparing upload")
  let speed = UploadSpeed(
    uploadedBytes: 1, bytesPerSecond: 3_000_000, averageBytesPerSecond: 2_000_000, peakBytesPerSecond: 5_000_000)
  #expect(
    speed.accessibilitySummary
      == "\(UploadSpeed.rateText(3_000_000)) now, average \(UploadSpeed.rateText(2_000_000)), peak \(UploadSpeed.rateText(5_000_000))"
  )
}

@Test func backingUpActivityWaitsForResticProgressBeforeReportingSamples() {
  let tracker = BackingUpActivity(throttle: .unthrottled)
  #expect(tracker.sampled(0, at: at(0)) == nil)
  let progress = BackupProgress(percentDone: 0.5, bytesDone: 10)
  guard case .backingUp(let reported, let baseline) = tracker.progressed(progress) else {
    Issue.record("expected a backing up activity")
    return
  }
  #expect(reported == progress)
  #expect(baseline.history.count == 1)
  guard case .backingUp(_, let speed)? = tracker.sampled(2_000_000, at: at(1)) else {
    Issue.record("expected a sample to report once restic has progressed")
    return
  }
  #expect(speed.uploadedBytes == 2_000_000)
  #expect(speed.history.count == 2)
}
