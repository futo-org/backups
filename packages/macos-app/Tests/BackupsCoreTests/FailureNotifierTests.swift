import BackupsCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private final class FakeNotificationCenter: FailureNotificationCenter {
  var current = NotificationAuthorization.authorized
  var answer: NotificationAuthorization? = .authorized
  var accepts = true
  var holdsRequest = false
  var holdsSubmission = false
  var holdsPost = false
  private(set) var requests = 0
  private(set) var submitted: [(id: String, notice: FailureNotice)] = []
  private(set) var withdrawn: [String] = []
  private(set) var withdrawAlls = 0
  private var heldRequest: CheckedContinuation<NotificationAuthorization?, Never>?
  private var heldSubmission: CheckedContinuation<Void, Never>?
  private var heldPost: CheckedContinuation<Bool, Never>?

  var posted: [FailureNotice] { submitted.map(\.notice) }

  func authorization() async -> NotificationAuthorization {
    current
  }

  func requestAuthorization() async -> NotificationAuthorization? {
    requests += 1
    guard holdsRequest else { return answer }
    return await withCheckedContinuation { heldRequest = $0 }
  }

  func post(_ notice: FailureNotice, id: String, isCurrent: @escaping @MainActor () -> Bool) async -> Bool {
    if holdsSubmission {
      await withCheckedContinuation { heldSubmission = $0 }
    }
    guard current == .authorized, isCurrent() else { return false }
    submitted.append((id, notice))
    guard holdsPost else { return accepts }
    return await withCheckedContinuation { heldPost = $0 }
  }

  func withdraw(id: String) {
    withdrawn.append(id)
  }

  func withdrawAll() {
    withdrawAlls += 1
  }

  func waitForHeldRequest() async {
    while heldRequest == nil { await Task.yield() }
  }

  func waitForHeldSubmission() async {
    while heldSubmission == nil { await Task.yield() }
  }

  func waitForHeldPost() async {
    while heldPost == nil { await Task.yield() }
  }

  func answerRequest(_ answer: NotificationAuthorization?) {
    heldRequest?.resume(returning: answer)
    heldRequest = nil
  }

  func releaseSubmission() {
    heldSubmission?.resume()
    heldSubmission = nil
  }

  func finishPost(accepted: Bool) {
    heldPost?.resume(returning: accepted)
    heldPost = nil
  }
}

@MainActor
private final class FakeHost: FailureNotificationHost {
  var config: AppConfig
  private(set) var saves = 0

  init(schedule: Schedule = .hourly, enabled: Bool? = true, permissionRequested: Bool = true) {
    config = AppConfig.defaults(host: "mac", home: "/Users/t")
    config.schedule = schedule
    config.failureNotificationsEnabled = enabled
    config.notificationPermissionRequestedAt = permissionRequested ? now.addingTimeInterval(-3600) : nil
  }

  func updateConfig(_ change: (inout AppConfig) -> Void) {
    change(&config)
    saves += 1
  }

  func failureNotice(for reason: BackupFailureReason) -> FailureNotice {
    FailureNotice(title: FailureNotice.title, body: "\(reason)")
  }
}

@MainActor
private func makeNotifier(_ host: FakeHost, _ center: FakeNotificationCenter) -> FailureNotifier {
  let notifier = FailureNotifier(center: center, now: { now })
  notifier.host = host
  return notifier
}

@MainActor
@Test func aScheduledFailureStreakPostsOnceAndRemembersItOnlyAfterTheNoticeIsAccepted() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)

  await notifier.backupFinished(.failed(.unreachable), scheduled: true)?.value
  #expect(center.posted.map(\.body) == ["unreachable"])
  #expect(host.config.failureNotifiedAt == now)

  #expect(notifier.backupFinished(.failed(.other), scheduled: true) == nil)
  #expect(center.posted.count == 1)

  notifier.backupFinished(.succeeded, scheduled: true)
  #expect(host.config.failureNotifiedAt == nil)
  #expect(center.withdrawAlls == 1)

  await notifier.backupFinished(.failed(.other), scheduled: true)?.value
  #expect(center.posted.count == 2)
  #expect(Set(center.submitted.map(\.id)).count == 2)
}

@MainActor
@Test func aManualOrStoppedRunNeverPosts() {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)
  #expect(notifier.backupFinished(.failed(.other), scheduled: false) == nil)
  #expect(notifier.backupFinished(.stopped, scheduled: true) == nil)
  #expect(notifier.backupFinished(.succeeded, scheduled: true) == nil)
  #expect(center.posted.isEmpty)
  #expect(center.withdrawAlls == 0)
  #expect(host.saves == 0)
}

@MainActor
@Test(arguments: [Bool?.none, false])
func aFailureWithNotificationsOffPostsNothingAndNeverAsks(enabled: Bool?) {
  let host = FakeHost(enabled: enabled, permissionRequested: false)
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)
  #expect(notifier.backupFinished(.failed(.unreachable), scheduled: true) == nil)
  #expect(center.requests == 0)
  #expect(center.posted.isEmpty)
}

@MainActor
@Test func aFailureNeverAsksForPermissionItself() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)

  await notifier.backupFinished(.failed(.unreachable), scheduled: true)?.value
  #expect(center.requests == 0)
  #expect(center.posted.count == 1)
  #expect(host.config.notificationPermissionRequestedAt == nil)
}

@MainActor
@Test func aFailureWithoutMacOSPermissionIsNotRemembered() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.current = .denied
  let notifier = makeNotifier(host, center)

  await notifier.backupFinished(.failed(.other), scheduled: true)?.value
  #expect(center.posted.isEmpty)
  #expect(host.config.failureNotifiedAt == nil)
  #expect(!notifier.isPostingNotice)
}

@MainActor
@Test func aRejectedNoticeLeavesTheStreakEligibleForTheNextFailure() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.accepts = false
  let notifier = makeNotifier(host, center)

  await notifier.backupFinished(.failed(.other), scheduled: true)?.value
  #expect(host.config.failureNotifiedAt == nil)
  #expect(!notifier.isPostingNotice)

  center.accepts = true
  await notifier.backupFinished(.failed(.other), scheduled: true)?.value
  #expect(center.posted.count == 2)
  #expect(host.config.failureNotifiedAt == now)
}

@MainActor
@Test func aFailureWaitsForAPermissionRequestAlreadyInProgress() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsRequest = true
  let notifier = makeNotifier(host, center)

  let asking = Task { await notifier.requestPermissionIfNeeded() }
  await center.waitForHeldRequest()
  let posting = notifier.backupFinished(.failed(.unreachable), scheduled: true)
  await Task.yield()
  #expect(center.posted.isEmpty)

  center.answerRequest(.authorized)
  await asking.value
  await posting?.value
  #expect(center.requests == 1)
  #expect(center.posted.count == 1)
  #expect(host.config.failureNotifiedAt == now)
}

@MainActor
@Test func aFailureDuringARequestThatMacOSDeniesPostsNothing() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsRequest = true
  let notifier = makeNotifier(host, center)

  let asking = Task { await notifier.requestPermissionIfNeeded() }
  await center.waitForHeldRequest()
  let posting = notifier.backupFinished(.failed(.unreachable), scheduled: true)
  center.current = .denied
  center.answerRequest(.denied)
  await asking.value
  await posting?.value
  #expect(center.posted.isEmpty)
  #expect(host.config.failureNotificationsEnabled == false)
  #expect(!notifier.isPostingNotice)
}

@MainActor
@Test func aSuccessBeforeTheNoticeIsSubmittedKeepsItFromBeingSubmitted() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.holdsSubmission = true
  let notifier = makeNotifier(host, center)

  let posting = notifier.backupFinished(.failed(.other), scheduled: true)
  await center.waitForHeldSubmission()
  notifier.backupFinished(.succeeded, scheduled: true)
  center.releaseSubmission()
  await posting?.value

  #expect(center.submitted.isEmpty)
  #expect(center.withdrawn.isEmpty)
  #expect(host.config.failureNotifiedAt == nil)
  #expect(!notifier.isPostingNotice)
}

@MainActor
@Test func aSuccessWhileTheNoticeIsBeingAddedWithdrawsOnlyThatNotice() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.holdsPost = true
  let notifier = makeNotifier(host, center)

  let posting = notifier.backupFinished(.failed(.other), scheduled: true)
  await center.waitForHeldPost()
  notifier.backupFinished(.succeeded, scheduled: true)
  #expect(center.withdrawAlls == 1)
  center.finishPost(accepted: true)
  await posting?.value

  #expect(center.withdrawn == center.submitted.map(\.id))
  #expect(host.config.failureNotifiedAt == nil)
}

@MainActor
@Test func aNoticeCancelledWhileBeingAddedIsWithdrawnAndNotRemembered() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.holdsPost = true
  let notifier = makeNotifier(host, center)

  let posting = notifier.backupFinished(.failed(.other), scheduled: true)
  await center.waitForHeldPost()
  notifier.cancelPendingNotice()
  center.finishPost(accepted: true)
  await posting?.value

  #expect(host.config.failureNotifiedAt == nil)
  #expect(center.withdrawn.count == 1)
}

@MainActor
@Test func endingAStreakWithoutAMarkerOnlyWithdraws() {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)
  notifier.endStreak()
  #expect(center.withdrawAlls == 1)
  #expect(host.saves == 0)
}

@MainActor
@Test(arguments: [
  (NotificationAuthorization?.some(.authorized), true, true),
  (.denied, false, true),
  (nil, false, false),
])
func turningNotificationsOnAsksMacOSAndKeepsTheAnswer(
  answer: NotificationAuthorization?, enabled: Bool, recorded: Bool
) async {
  let host = FakeHost(enabled: nil, permissionRequested: false)
  let center = FakeNotificationCenter()
  center.answer = answer
  let notifier = makeNotifier(host, center)

  await notifier.setEnabled(true)
  #expect(center.requests == 1)
  #expect(host.config.failureNotificationsEnabled == enabled)
  #expect((host.config.notificationPermissionRequestedAt == now) == recorded)
  #expect(notifier.toggle.isOn == enabled)
  #expect(notifier.toggle.showsDeniedNote == (answer == .denied))
  #expect(!host.config.showsFailureNotificationHint)
}

@MainActor
@Test func turningNotificationsOnShowsItAsOnWhileMacOSIsAsking() async {
  let host = FakeHost(enabled: nil, permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsRequest = true
  let notifier = makeNotifier(host, center)

  let turningOn = Task { await notifier.setEnabled(true) }
  await center.waitForHeldRequest()
  #expect(notifier.toggle.isOn)
  #expect(notifier.isRequestingAuthorization)
  center.answerRequest(.authorized)
  await turningOn.value
  #expect(!notifier.isRequestingAuthorization)
  #expect(notifier.toggle.isOn)
}

@MainActor
@Test func turningNotificationsOffStopsNoticesWithoutAskingMacOS() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.holdsSubmission = true
  let notifier = makeNotifier(host, center)

  let posting = notifier.backupFinished(.failed(.other), scheduled: true)
  await center.waitForHeldSubmission()
  await notifier.setEnabled(false)
  center.releaseSubmission()
  await posting?.value

  #expect(center.requests == 0)
  #expect(host.config.failureNotificationsEnabled == false)
  #expect(center.submitted.isEmpty)
  #expect(notifier.backupFinished(.failed(.other), scheduled: true) == nil)
}

@MainActor
@Test func turningNotificationsOffWhileMacOSIsAskingStaysOff() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsRequest = true
  let notifier = makeNotifier(host, center)

  let asking = Task { await notifier.requestPermissionIfNeeded() }
  await center.waitForHeldRequest()
  await notifier.setEnabled(false)
  center.answerRequest(.authorized)
  await asking.value

  #expect(host.config.failureNotificationsEnabled == false)
  #expect(host.config.notificationPermissionRequestedAt == now)
  #expect(!notifier.toggle.isOn)
}

@MainActor
@Test func aSettingDeniedInSystemSettingsShowsAsOffWithTheNote() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.current = .denied
  let notifier = makeNotifier(host, center)

  #expect(notifier.toggle == FailureNotificationToggle(enabled: true, authorization: nil))
  await notifier.refreshAuthorization()
  #expect(!notifier.toggle.isOn)
  #expect(notifier.toggle.showsDeniedNote)
  #expect(host.config.failureNotificationsEnabled == true)
}

@MainActor
@Test func turningNotificationsOnFromTheHintHidesItForGood() async {
  let host = FakeHost(enabled: nil, permissionRequested: false)
  let center = FakeNotificationCenter()
  center.answer = nil
  let notifier = makeNotifier(host, center)
  #expect(host.config.showsFailureNotificationHint)

  await notifier.setEnabled(true)
  #expect(host.config.failureNotificationsEnabled == false)
  #expect(host.config.failureNotificationHintDismissedAt == now)
  #expect(!host.config.showsFailureNotificationHint)
}

@MainActor
@Test func dismissingTheHintHidesItWithoutAskingMacOS() {
  let host = FakeHost(enabled: nil, permissionRequested: false)
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)

  notifier.dismissHint()
  #expect(!host.config.showsFailureNotificationHint)
  #expect(host.config.failureNotificationsEnabled == nil)
  #expect(center.requests == 0)
}

@MainActor
@Test func aPermissionRequestThatFailsIsNotRecordedAndIsAskedAgain() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.answer = nil
  let notifier = makeNotifier(host, center)

  await notifier.requestPermissionIfNeeded()
  #expect(host.config.notificationPermissionRequestedAt == nil)
  #expect(host.config.failureNotificationsEnabled == true)

  center.answer = .authorized
  await notifier.requestPermissionIfNeeded()
  #expect(center.requests == 2)
  #expect(host.config.notificationPermissionRequestedAt == now)

  await notifier.requestPermissionIfNeeded()
  #expect(center.requests == 2)
}

@MainActor
@Test func concurrentPermissionRequestsShareOnePrompt() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsRequest = true
  let notifier = makeNotifier(host, center)

  let first = Task { await notifier.requestPermissionIfNeeded() }
  await center.waitForHeldRequest()
  let second = Task { await notifier.setEnabled(true) }
  while host.config.failureNotificationHintDismissedAt == nil { await Task.yield() }
  center.answerRequest(.authorized)
  await first.value
  await second.value
  #expect(center.requests == 1)
  #expect(host.config.notificationPermissionRequestedAt == now)
  #expect(host.config.failureNotificationsEnabled == true)
}

@MainActor
@Test func aPermissionAnswerAfterTheMacWasUnlinkedIsDropped() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsRequest = true
  let notifier = makeNotifier(host, center)

  let asking = Task { await notifier.requestPermissionIfNeeded() }
  let turningOn = Task { await notifier.setEnabled(true) }
  await center.waitForHeldRequest()
  while host.config.failureNotificationHintDismissedAt == nil { await Task.yield() }
  let saves = host.saves
  notifier.invalidate()
  #expect(!notifier.isRequestingAuthorization)
  center.answerRequest(nil)
  await asking.value
  await turningOn.value

  #expect(host.saves == saves)
  #expect(host.config.notificationPermissionRequestedAt == nil)
  #expect(notifier.authorization == nil)
}

@MainActor
@Test func aNoticeBeingPostedWhenTheMacIsUnlinkedIsNotRemembered() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.holdsPost = true
  let notifier = makeNotifier(host, center)

  let posting = notifier.backupFinished(.failed(.other), scheduled: true)
  await center.waitForHeldPost()
  notifier.invalidate()
  center.finishPost(accepted: true)
  await posting?.value

  #expect(host.config.failureNotifiedAt == nil)
  #expect(center.withdrawn == center.submitted.map(\.id))
}

@MainActor
@Test(arguments: [
  (Schedule.manual, Schedule.hourly, true, 1),
  (.manual, .daily(hour: 9, minute: 0), true, 1),
  (.manual, .hourly, false, 0),
  (.daily(hour: 12, minute: 0), .daily(hour: 9, minute: 0), true, 0),
  (.hourly, .weekly(weekday: 2, hour: 9, minute: 0), true, 0),
  (.hourly, .manual, true, 0),
])
func onlyTurningTheScheduleOnWithNotificationsOnAsksForPermission(
  previous: Schedule, schedule: Schedule, enabled: Bool, requests: Int
) async {
  let host = FakeHost(schedule: schedule, enabled: enabled ? true : nil, permissionRequested: false)
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)
  await notifier.scheduleChanged(from: previous)
  #expect(center.requests == requests)
}
