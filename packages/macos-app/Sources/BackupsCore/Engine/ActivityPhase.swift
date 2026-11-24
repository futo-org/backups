import Foundation

public enum ActivityPhase: Equatable, Sendable {
  case preparing
  case backingUp
  case finishing(FinishingStep)
  case pruning
  case restoring
  case changingRecoveryKey

  public var isCancellable: Bool {
    self != .changingRecoveryKey
  }
}

public enum ActivitySample: Equatable, Sendable {
  case backup(BackupSample)
  case restore(RestoreStep)
}

public struct BackupSample: Equatable, Sendable {
  public var progress: BackupProgress
  public var speed: UploadSpeed

  public init(progress: BackupProgress, speed: UploadSpeed) {
    self.progress = progress
    self.speed = speed
  }
}

extension EngineActivity {
  public var phase: ActivityPhase {
    switch self {
    case .preparing: return .preparing
    case .backingUp: return .backingUp
    case .finishing(let step): return .finishing(step)
    case .pruning: return .pruning
    case .restoring: return .restoring
    case .changingRecoveryKey: return .changingRecoveryKey
    }
  }

  public var sample: ActivitySample? {
    switch self {
    case .backingUp(let progress, let speed): return .backup(BackupSample(progress: progress, speed: speed))
    case .restoring(let step): return .restore(step)
    default: return nil
    }
  }
}

extension BackupProgress {
  public var wholePercentFraction: Double {
    percentDone.wholePercentFraction
  }
}

extension Double {
  public var wholePercentFraction: Double {
    (self * 100).rounded() / 100
  }
}
