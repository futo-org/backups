import Foundation

public enum ActivityPhase: Equatable, Sendable {
  case preparing
  case backingUp
  case finishing(FinishingStep)
  case pruning
  case restoring
  case changingRecoveryKey
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

  public var backupSample: BackupSample? {
    guard case .backingUp(let progress, let speed) = self else { return nil }
    return BackupSample(progress: progress, speed: speed)
  }
}

extension BackupProgress {
  public var wholePercentFraction: Double {
    (percentDone * 100).rounded() / 100
  }
}
