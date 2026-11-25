import Foundation
import Observation

@MainActor
public protocol FailureNotificationCenter: AnyObject {
  func authorization() async -> NotificationAuthorization
  func requestAuthorization() async -> NotificationAuthorization?
  func post(_ notice: FailureNotice, id: String, isCurrent: @escaping @MainActor () -> Bool) async -> Bool
  func withdraw(id: String)
  func withdrawAll()
}

@MainActor
public protocol FailureNotificationHost: AnyObject {
  var config: AppConfig { get }
  func updateConfig(_ change: (inout AppConfig) -> Void)
  func failureNotice(for reason: BackupFailureReason) -> FailureNotice
}

@MainActor
@Observable
public final class FailureNotifier {
  @ObservationIgnored public weak var host: (any FailureNotificationHost)?
  public private(set) var authorization: NotificationAuthorization?
  public private(set) var isRequestingAuthorization = false
  @ObservationIgnored private let center: any FailureNotificationCenter
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private var authorizationRequest: Task<NotificationAuthorization?, Never>?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var pendingNotice: UUID?

  public init(center: any FailureNotificationCenter, now: @escaping () -> Date = Date.init) {
    self.center = center
    self.now = now
  }

  public var isPostingNotice: Bool { pendingNotice != nil }

  public var toggle: FailureNotificationToggle {
    FailureNotificationToggle(enabled: host?.config.notifiesOnFailure == true, authorization: authorization)
  }

  public func refreshAuthorization() async {
    authorization = await center.authorization()
  }

  public func requestPermissionIfNeeded() async {
    guard host?.config.shouldRequestNotificationPermission == true else { return }
    _ = await requestAuthorization()
  }

  public func scheduleChanged(from previous: Schedule) async {
    guard previous == .manual else { return }
    await requestPermissionIfNeeded()
  }

  public func setEnabled(_ enabled: Bool) async {
    host?.updateConfig {
      $0.failureNotificationsEnabled = enabled
      $0.failureNotificationHintDismissedAt = $0.failureNotificationHintDismissedAt ?? now()
    }
    guard enabled else {
      pendingNotice = nil
      return
    }
    let generation = generation
    let answer = await requestAuthorization()
    guard generation == self.generation, answer == nil else { return }
    host?.updateConfig { $0.failureNotificationsEnabled = false }
  }

  public func dismissHint() {
    host?.updateConfig { $0.failureNotificationHintDismissedAt = now() }
  }

  public func invalidate() {
    generation += 1
    authorizationRequest = nil
    isRequestingAuthorization = false
    pendingNotice = nil
  }

  @discardableResult
  public func backupFinished(_ outcome: BackupRunOutcome, scheduled: Bool) -> Task<Void, Never>? {
    guard let host else { return nil }
    let step = FailureNoticeStep.after(
      outcome, scheduled: scheduled, notifies: host.config.notifiesOnFailure,
      streakNotified: host.config.failureNotifiedAt != nil, noticePending: pendingNotice != nil)
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
    center.withdrawAll()
  }

  public func cancelPendingNotice() {
    pendingNotice = nil
  }

  private func requestAuthorization() async -> NotificationAuthorization? {
    if let authorizationRequest {
      return await authorizationRequest.value
    }
    let generation = generation
    let request = Task { () -> NotificationAuthorization? in
      let answer = await center.requestAuthorization()
      guard generation == self.generation else { return nil }
      authorizationRequest = nil
      isRequestingAuthorization = false
      if let answer {
        record(answer)
      }
      return answer
    }
    authorizationRequest = request
    isRequestingAuthorization = true
    return await request.value
  }

  private func record(_ answer: NotificationAuthorization) {
    authorization = answer
    host?.updateConfig {
      $0.notificationPermissionRequestedAt = now()
      if answer == .denied {
        $0.failureNotificationsEnabled = false
      }
    }
  }

  private func post(_ reason: BackupFailureReason) -> Task<Void, Never> {
    let token = UUID()
    pendingNotice = token
    return Task {
      if let authorizationRequest {
        _ = await authorizationRequest.value
      }
      guard pendingNotice == token, host?.config.notifiesOnFailure == true,
        let notice = host?.failureNotice(for: reason)
      else {
        if pendingNotice == token { pendingNotice = nil }
        return
      }
      let id = "backup-failed.\(token.uuidString)"
      let accepted = await center.post(notice, id: id) { self.pendingNotice == token }
      guard pendingNotice == token else {
        if accepted { center.withdraw(id: id) }
        return
      }
      pendingNotice = nil
      if accepted {
        host?.updateConfig { $0.failureNotifiedAt = now() }
      }
    }
  }
}
