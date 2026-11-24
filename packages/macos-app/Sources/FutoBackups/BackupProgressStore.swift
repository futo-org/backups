import BackupsCore
import Foundation
import Observation

@MainActor
@Observable
final class BackupProgressStore {
  private(set) var progress: BackupProgress?
  private(set) var speed: UploadSpeed?
  private(set) var wholePercentFraction: Double?

  @ObservationIgnored private var throttle = PublishThrottle<BackupSample>(interval: .milliseconds(500))
  @ObservationIgnored private var flushTask: Task<Void, Never>?
  @ObservationIgnored private let clock = ContinuousClock()

  func receive(_ sample: BackupSample) {
    switch throttle.offer(sample, at: clock.now) {
    case .publish(let sample):
      flushTask?.cancel()
      flushTask = nil
      show(sample)
    case .flush(let delay):
      flushTask = Task { [weak self, clock] in
        try? await clock.sleep(for: delay)
        guard !Task.isCancelled else { return }
        self?.flush()
      }
    case .hold:
      break
    }
  }

  func clear() {
    flushTask?.cancel()
    flushTask = nil
    throttle.reset()
    if progress != nil { progress = nil }
    if speed != nil { speed = nil }
    if wholePercentFraction != nil { wholePercentFraction = nil }
  }

  private func flush() {
    flushTask = nil
    if let sample = throttle.flush(at: clock.now) {
      show(sample)
    }
  }

  private func show(_ sample: BackupSample) {
    if progress != sample.progress { progress = sample.progress }
    if speed != sample.speed { speed = sample.speed }
    let fraction = sample.progress.wholePercentFraction
    if wholePercentFraction != fraction { wholePercentFraction = fraction }
  }
}
