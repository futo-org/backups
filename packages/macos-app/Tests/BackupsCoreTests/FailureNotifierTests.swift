import BackupsCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private final class FakeNotificationCenter: FailureNotificationCenter {
  var permissionDecides = true
  var accepts = true
  var holdsPermission = false
  var holdsPost = false
  private(set) var permissionRequests = 0
  private(set) var posted: [FailureNotice] = []
  private(set) var withdrawals = 0
  private var heldPermission: CheckedContinuation<Bool, Never>?
  private var heldPost: CheckedContinuation<Bool, Never>?

  func requestPermission() async -> Bool {
    permissionRequests += 1
    guard holdsPermission else { return permissionDecides }
    return await withCheckedContinuation { heldPermission = $0 }
  }

  func post(_ notice: FailureNotice) async -> Bool {
    posted.append(notice)
    guard holdsPost else { return accepts }
    return await withCheckedContinuation { heldPost = $0 }
  }

  func withdraw() {
    withdrawals += 1
  }

  func waitForHeldPermission() async {
    while heldPermission == nil { await Task.yield() }
  }

  func waitForHeldPost() async {
    while heldPost == nil { await Task.yield() }
  }

  func answerPermission(_ decided: Bool) {
    heldPermission?.resume(returning: decided)
    heldPermission = nil
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

  init(schedule: Schedule = .hourly, permissionRequested: Bool = true) {
    config = AppConfig.defaults(host: "mac", home: "/Users/t")
    config.schedule = schedule
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
private func makeNotifier(
  _ host: FakeHost, _ center: FakeNotificationCenter
) -> FailureNotifier {
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
  #expect(center.withdrawals == 1)

  await notifier.backupFinished(.failed(.other), scheduled: true)?.value
  #expect(center.posted.count == 2)
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
  #expect(center.withdrawals == 0)
  #expect(host.saves == 0)
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
@Test func aFailureBeforePermissionWasAskedAsksFirstAndPostsOnceAnswered() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsPermission = true
  let notifier = makeNotifier(host, center)

  let posting = notifier.backupFinished(.failed(.unreachable), scheduled: true)
  await center.waitForHeldPermission()
  #expect(center.posted.isEmpty)
  #expect(notifier.backupFinished(.failed(.unreachable), scheduled: true) == nil)

  center.answerPermission(true)
  await posting?.value
  #expect(center.permissionRequests == 1)
  #expect(host.config.notificationPermissionRequestedAt == now)
  #expect(center.posted.count == 1)
  #expect(host.config.failureNotifiedAt == now)
}

@MainActor
@Test func aSuccessWhilePermissionIsPendingDiscardsTheQueuedNotice() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsPermission = true
  let notifier = makeNotifier(host, center)

  let posting = notifier.backupFinished(.failed(.other), scheduled: true)
  await center.waitForHeldPermission()
  notifier.backupFinished(.succeeded, scheduled: true)
  center.answerPermission(true)
  await posting?.value

  #expect(center.posted.isEmpty)
  #expect(host.config.failureNotifiedAt == nil)
  #expect(!notifier.isPostingNotice)
}

@MainActor
@Test func aSuccessWhileTheNoticeIsBeingAddedWithdrawsItOnceAdded() async {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  center.holdsPost = true
  let notifier = makeNotifier(host, center)

  let posting = notifier.backupFinished(.failed(.other), scheduled: true)
  await center.waitForHeldPost()
  notifier.backupFinished(.succeeded, scheduled: true)
  #expect(center.withdrawals == 1)
  center.finishPost(accepted: true)
  await posting?.value

  #expect(center.withdrawals == 2)
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
  #expect(center.withdrawals == 1)
}

@MainActor
@Test func endingAStreakWithoutAMarkerOnlyWithdraws() {
  let host = FakeHost()
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)
  notifier.endStreak()
  #expect(center.withdrawals == 1)
  #expect(host.saves == 0)
}

@MainActor
@Test func aPermissionRequestThatFailsIsNotRecordedAndIsAskedAgain() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.permissionDecides = false
  let notifier = makeNotifier(host, center)

  await notifier.requestPermissionIfNeeded()
  #expect(host.config.notificationPermissionRequestedAt == nil)

  center.permissionDecides = true
  await notifier.requestPermissionIfNeeded()
  #expect(center.permissionRequests == 2)
  #expect(host.config.notificationPermissionRequestedAt == now)

  await notifier.requestPermissionIfNeeded()
  #expect(center.permissionRequests == 2)
}

@MainActor
@Test func concurrentPermissionRequestsShareOnePrompt() async {
  let host = FakeHost(permissionRequested: false)
  let center = FakeNotificationCenter()
  center.holdsPermission = true
  let notifier = makeNotifier(host, center)

  let first = Task { await notifier.requestPermissionIfNeeded() }
  await center.waitForHeldPermission()
  let second = Task { await notifier.requestPermissionIfNeeded() }
  await Task.yield()
  center.answerPermission(true)
  await first.value
  await second.value
  #expect(center.permissionRequests == 1)
  #expect(host.saves == 1)
}

@MainActor
@Test(arguments: [
  (Schedule.manual, Schedule.hourly, 1),
  (.manual, .daily(hour: 9, minute: 0), 1),
  (.daily(hour: 12, minute: 0), .daily(hour: 9, minute: 0), 0),
  (.hourly, .weekly(weekday: 2, hour: 9, minute: 0), 0),
  (.hourly, .manual, 0),
])
func onlyTurningTheScheduleOnAsksForPermission(previous: Schedule, schedule: Schedule, requests: Int) async {
  let host = FakeHost(schedule: schedule, permissionRequested: false)
  let center = FakeNotificationCenter()
  let notifier = makeNotifier(host, center)
  await notifier.scheduleChanged(from: previous)
  #expect(center.permissionRequests == requests)
}
