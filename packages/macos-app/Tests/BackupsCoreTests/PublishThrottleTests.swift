import Foundation
import Testing

@testable import BackupsCore

private let base = ContinuousClock.now

private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
  base + .milliseconds(milliseconds)
}

@Test func firstValuePublishesImmediately() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  #expect(throttle.offer(1, at: at(0)) == .publish(1))
}

@Test func valuesAfterTheIntervalPublishImmediately() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  _ = throttle.offer(1, at: at(0))
  #expect(throttle.offer(2, at: at(500)) == .publish(2))
  #expect(throttle.offer(3, at: at(1200)) == .publish(3))
}

@Test func unchangedValuesAreNeverPublished() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  _ = throttle.offer(1, at: at(0))
  #expect(throttle.offer(1, at: at(600)) == .hold)
  #expect(throttle.offer(1, at: at(5000)) == .hold)
}

@Test func valuesInsideTheIntervalWaitForOneFlush() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  _ = throttle.offer(1, at: at(0))
  #expect(throttle.offer(2, at: at(200)) == .flush(after: .milliseconds(300)))
  #expect(throttle.offer(3, at: at(300)) == .hold)
  #expect(throttle.flush(at: at(500)) == 3)
  #expect(throttle.flush(at: at(600)) == nil)
}

@Test func flushRestartsTheInterval() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  _ = throttle.offer(1, at: at(0))
  _ = throttle.offer(2, at: at(100))
  _ = throttle.flush(at: at(500))
  #expect(throttle.offer(3, at: at(700)) == .flush(after: .milliseconds(300)))
  #expect(throttle.flush(at: at(1000)) == 3)
}

@Test func anImmediatePublishOvertakingAScheduledFlushStartsAFreshWindow() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  _ = throttle.offer(1, at: at(0))
  #expect(throttle.offer(2, at: at(100)) == .flush(after: .milliseconds(400)))
  #expect(throttle.offer(3, at: at(500)) == .publish(3))
  #expect(throttle.offer(4, at: at(600)) == .flush(after: .milliseconds(400)))
  #expect(throttle.flush(at: at(1000)) == 4)
}

@Test func anImmediateOfferInsideTheIntervalPublishesAndDropsThePendingValue() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  _ = throttle.offer(1, at: at(0))
  #expect(throttle.offer(2, at: at(100)) == .flush(after: .milliseconds(400)))
  #expect(throttle.offer(10, at: at(200), immediately: true) == .publish(10))
  #expect(throttle.flush(at: at(500)) == nil)
  #expect(throttle.offer(11, at: at(300)) == .flush(after: .milliseconds(400)))
  #expect(throttle.flush(at: at(700)) == 11)
}

@Test func returningToThePublishedValueCancelsThePendingOne() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  _ = throttle.offer(1, at: at(0))
  _ = throttle.offer(2, at: at(100))
  #expect(throttle.offer(1, at: at(200)) == .hold)
  #expect(throttle.flush(at: at(500)) == nil)
}

@Test func publishesAtMostTwicePerSecondUnderSteadyUpdates() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  var published: [Int] = []
  var flushAt: Int?
  for tick in 0..<30 {
    let now = tick * 100
    if let due = flushAt, due <= now, let value = throttle.flush(at: at(due)) {
      published.append(value)
      flushAt = nil
    }
    switch throttle.offer(tick, at: at(now)) {
    case .publish(let value): published.append(value)
    case .flush(let delay): flushAt = now + Int(delay / .milliseconds(1))
    case .hold: break
    }
  }
  #expect(published == [0, 4, 9, 14, 19, 24])
}

@Test func resetForgetsThePublishedValue() {
  var throttle = PublishThrottle<Int>(interval: .milliseconds(500))
  _ = throttle.offer(1, at: at(0))
  _ = throttle.offer(2, at: at(100))
  throttle.reset()
  #expect(throttle.flush(at: at(500)) == nil)
  #expect(throttle.offer(1, at: at(200)) == .publish(1))
}
