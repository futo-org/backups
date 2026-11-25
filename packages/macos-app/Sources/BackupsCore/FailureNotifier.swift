import Foundation

@MainActor
public protocol FailureNotificationCenter: AnyObject {
  func requestPermission() async -> Bool
  func post(_ notice: FailureNotice) async -> Bool
  func withdraw()
}

@MainActor
public protocol FailureNotificationHost: AnyObject {
  var config: AppConfig { get }
  func updateConfig(_ change: (inout AppConfig) -> Void)
  func failureNotice(for reason: BackupFailureReason) -> FailureNotice
}

@MainActor
public final class FailureNotifier {
  public weak var host: (any FailureNotificationHost)?
  private let center: any FailureNotificationCenter
  private let now: () -> Date
  private var permissionRequest: Task<Void, Never>?
  private var pendingNotice: UUID?

  public init(center: any FailureNotificationCenter, now: @escaping () -> Date = Date.init) {
    self.center = center
    self.now = now
  }

  public var isPostingNotice: Bool { pendingNotice != nil }

  public func requestPermissionIfNeeded() async {
    if let permissionRequest {
      await permissionRequest.value
      return
    }
    guard host?.config.shouldRequestNotificationPermission == true else { return }
    let request = Task {
      if await center.requestPermission() {
        host?.updateConfig { $0.notificationPermissionRequestedAt = now() }
      }
      permissionRequest = nil
    }
    permissionRequest = request
    await request.value
  }

  public func scheduleChanged(from previous: Schedule) async {
    guard previous == .manual else { return }
    await requestPermissionIfNeeded()
  }

  @discardableResult
  public func backupFinished(_ outcome: BackupRunOutcome, scheduled: Bool) -> Task<Void, Never>? {
    guard let host else { return nil }
    let step = FailureNoticeStep.after(
      outcome, scheduled: scheduled, streakNotified: host.config.failureNotifiedAt != nil,
      noticePending: pendingNotice != nil)
    switch step {
    case .nothing:
      return nil
    case .endStreak:
      endStreak()
      return nil
    case .post(let reason):
      return post(reason)
    }
  }

  public func endStreak() {
    pendingNotice = nil
    if host?.config.failureNotifiedAt != nil {
      host?.updateConfig { $0.failureNotifiedAt = nil }
    }
    center.withdraw()
  }

  public func cancelPendingNotice() {
    pendingNotice = nil
  }

  private func post(_ reason: BackupFailureReason) -> Task<Void, Never> {
    let token = UUID()
    pendingNotice = token
    return Task {
      await requestPermissionIfNeeded()
      guard pendingNotice == token, let notice = host?.failureNotice(for: reason) else { return }
      let accepted = await center.post(notice)
      guard pendingNotice == token else {
        if accepted, pendingNotice == nil, host?.config.failureNotifiedAt == nil {
          center.withdraw()
        }
        return
      }
      pendingNotice = nil
      if accepted {
        host?.updateConfig { $0.failureNotifiedAt = now() }
      }
    }
  }
}
