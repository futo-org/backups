import Foundation

public struct PublishThrottle<Value: Equatable & Sendable>: Sendable {
  public enum Decision: Equatable, Sendable {
    case publish(Value)
    case flush(after: Duration)
    case hold
  }

  public let interval: Duration
  private var published: Value?
  private var publishedAt: ContinuousClock.Instant?
  private var pending: Value?
  private var flushScheduled = false

  public init(interval: Duration) {
    self.interval = interval
  }

  public mutating func offer(_ value: Value, at now: ContinuousClock.Instant) -> Decision {
    guard value != published else {
      pending = nil
      return .hold
    }
    if let publishedAt, publishedAt.duration(to: now) < interval {
      pending = value
      guard !flushScheduled else { return .hold }
      flushScheduled = true
      return .flush(after: interval - publishedAt.duration(to: now))
    }
    flushScheduled = false
    record(value, at: now)
    return .publish(value)
  }

  public mutating func flush(at now: ContinuousClock.Instant) -> Value? {
    flushScheduled = false
    guard let value = pending else { return nil }
    record(value, at: now)
    return value
  }

  public mutating func reset() {
    self = PublishThrottle(interval: interval)
  }

  private mutating func record(_ value: Value, at now: ContinuousClock.Instant) {
    published = value
    publishedAt = now
    pending = nil
  }
}
