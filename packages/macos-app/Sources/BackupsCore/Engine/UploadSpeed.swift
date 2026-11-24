import Foundation

public struct UploadSpeed: Equatable, Sendable {
  public struct Point: Equatable, Sendable {
    public var secondsAgo: Double
    public var bytesPerSecond: Double

    public init(secondsAgo: Double, bytesPerSecond: Double) {
      self.secondsAgo = secondsAgo
      self.bytesPerSecond = bytesPerSecond
    }
  }

  public static let historySeconds: Double = 120
  static let minimumChartCeiling: Double = 100_000
  static let chartHeadroom = 1.15

  public var uploadedBytes: Int64
  public var bytesPerSecond: Double
  public var averageBytesPerSecond: Double
  public var peakBytesPerSecond: Double
  public var history: [Point]
  public var throttle: Throttle

  public init(
    uploadedBytes: Int64 = 0, bytesPerSecond: Double = 0, averageBytesPerSecond: Double = 0,
    peakBytesPerSecond: Double = 0, history: [Point] = [], throttle: Throttle = .unthrottled
  ) {
    self.uploadedBytes = uploadedBytes
    self.bytesPerSecond = bytesPerSecond
    self.averageBytesPerSecond = averageBytesPerSecond
    self.peakBytesPerSecond = peakBytesPerSecond
    self.history = history
    self.throttle = throttle
  }

  public var hasStarted: Bool { uploadedBytes > 0 }

  public var chartCeiling: Double {
    Self.chartCeiling(for: history.map(\.bytesPerSecond).max() ?? 0)
  }

  static func chartCeiling(for highest: Double) -> Double {
    let target = max(highest * chartHeadroom, minimumChartCeiling)
    let magnitude = pow(10, floor(log10(target)))
    let step = [1, 2, 2.5, 5, 10].first { $0 * magnitude >= target } ?? 10
    return step * magnitude
  }

  public static func rateText(_ bytesPerSecond: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: Int64(max(0, bytesPerSecond).rounded())) + "/s"
  }

  public var accessibilitySummary: String {
    guard hasStarted else { return "Preparing upload" }
    return
      "\(Self.rateText(bytesPerSecond)) now, average \(Self.rateText(averageBytesPerSecond)), peak \(Self.rateText(peakBytesPerSecond))"
  }
}

public struct UploadSpeedMeter: Sendable {
  public static let window: Double = 8

  private struct Sample {
    var at: ContinuousClock.Instant
    var total: Int64
  }

  private struct Reading {
    var at: ContinuousClock.Instant
    var bytesPerSecond: Double
  }

  private var samples: [Sample] = []
  private var readings: [Reading] = []
  private var lastReported: Int64 = 0
  private var resetOffset: Int64 = 0
  private var uploadStartedAt: ContinuousClock.Instant?
  public private(set) var speed: UploadSpeed

  public init(throttle: Throttle = .unthrottled) {
    speed = UploadSpeed(throttle: throttle)
  }

  @discardableResult
  public mutating func record(_ reported: Int64, at instant: ContinuousClock.Instant) -> UploadSpeed {
    if let last = samples.last, instant <= last.at {
      return speed
    }
    if reported < lastReported {
      resetOffset += lastReported
    }
    lastReported = reported
    let total = resetOffset + reported
    if uploadStartedAt == nil, total > 0 {
      uploadStartedAt = samples.last?.at ?? instant
    }
    samples.append(Sample(at: instant, total: total))
    while samples.count > 1, Self.seconds(samples[1].at, instant) >= Self.window {
      samples.removeFirst()
    }

    let current = currentBytesPerSecond(at: instant)
    readings.append(Reading(at: instant, bytesPerSecond: current))
    while let first = readings.first, Self.seconds(first.at, instant) > UploadSpeed.historySeconds {
      readings.removeFirst()
    }

    var average = 0.0
    if let uploadStartedAt {
      let elapsed = Self.seconds(uploadStartedAt, instant)
      average = elapsed > 0 ? Double(total) / elapsed : 0
    }
    speed.uploadedBytes = total
    speed.bytesPerSecond = current
    speed.averageBytesPerSecond = average
    speed.peakBytesPerSecond = max(speed.peakBytesPerSecond, current)
    speed.history = readings.map {
      UploadSpeed.Point(secondsAgo: Self.seconds($0.at, instant), bytesPerSecond: $0.bytesPerSecond)
    }
    return speed
  }

  // Each interval's bytes are spread evenly over it and weighted by a triangular kernel that falls from 1 now to 0
  // `window` seconds ago, so a pack landing in one tick fades out over the window instead of dropping to zero on
  // the next tick, and a stall reaches exactly zero once the window has passed.
  private func currentBytesPerSecond(at now: ContinuousClock.Instant) -> Double {
    var weightedBytes = 0.0
    var weightedSeconds = 0.0
    for (previous, next) in zip(samples, samples.dropFirst()) {
      let duration = Self.seconds(previous.at, next.at)
      let newestAge = Self.seconds(next.at, now)
      let oldestAge = min(Self.seconds(previous.at, now), Self.window)
      guard duration > 0, oldestAge > newestAge else { continue }
      let weight = Self.kernelArea(from: newestAge, to: oldestAge)
      weightedBytes += weight * Double(next.total - previous.total) / duration
      weightedSeconds += weight
    }
    return weightedSeconds > 0 ? weightedBytes / weightedSeconds : 0
  }

  private static func kernelArea(from newest: Double, to oldest: Double) -> Double {
    (oldest - newest) - (oldest * oldest - newest * newest) / (2 * window)
  }

  private static func seconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
    let components = from.duration(to: to).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
  }

  public static func ticks(every interval: Duration) -> AsyncStream<ContinuousClock.Instant> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task {
        let clock = ContinuousClock()
        while !Task.isCancelled {
          continuation.yield(clock.now)
          try? await clock.sleep(for: interval)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
