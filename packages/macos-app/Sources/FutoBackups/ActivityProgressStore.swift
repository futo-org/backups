import BackupsCore
import Foundation
import Observation

@MainActor
@Observable
final class ActivityProgressStore {
  private(set) var progress: BackupProgress?
  private(set) var speed: UploadSpeed?
  private(set) var restore: RestoreStep?
  private(set) var wholePercentFraction: Double?

  @ObservationIgnored private var throttle = PublishThrottle<ActivitySample>(interval: .milliseconds(500))
  @ObservationIgnored private var flushTask: Task<Void, Never>?
  @ObservationIgnored private let clock = ContinuousClock()

  func receive(_ sample: ActivitySample) {
    switch throttle.offer(sample, at: clock.now, immediately: sample.startsNewRestorePart(after: restore)) {
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
    show(progress: nil, speed: nil, restore: nil, fraction: nil)
  }

  private func flush() {
    flushTask = nil
    if let sample = throttle.flush(at: clock.now) {
      show(sample)
    }
  }

  private func show(_ sample: ActivitySample) {
    switch sample {
    case .backup(let backup):
      show(
        progress: backup.progress, speed: backup.speed, restore: nil, fraction: backup.progress.wholePercentFraction)
    case .restore(let step):
      show(progress: nil, speed: nil, restore: step, fraction: step.overallFraction?.wholePercentFraction)
    }
  }

  private func show(progress: BackupProgress?, speed: UploadSpeed?, restore: RestoreStep?, fraction: Double?) {
    if self.progress != progress { self.progress = progress }
    if self.speed != speed { self.speed = speed }
    if self.restore != restore { self.restore = restore }
    if wholePercentFraction != fraction { wholePercentFraction = fraction }
  }
}
