import BackupsCore
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private var utc: Calendar {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  calendar.locale = Locale(identifier: "en_US")
  return calendar
}

private func notice(_ reason: BackupFailureReason, retryAt: Date?) -> FailureNotice {
  FailureNotice(
    reason: reason, server: "FUTO Cloud", retryAt: retryAt, now: now, calendar: utc,
    locale: Locale(identifier: "en_US"))
}

private func record(_ status: BackupStatus, message: String? = nil) -> RunRecord {
  RunRecord(startedAt: now, finishedAt: now, status: status, message: message)
}

@Test(arguments: [
  (BackupRunOutcome.failed(.unreachable), true, true, false, false, FailureNoticeStep.post(.unreachable)),
  (.failed(.unreachable), true, false, false, false, .nothing),
  (.failed(.other), true, true, true, false, .nothing),
  (.failed(.other), true, true, false, true, .nothing),
  (.failed(.signedOut), false, true, false, false, .nothing),
  (.succeeded, true, true, true, false, .endStreak),
  (.succeeded, true, false, true, false, .endStreak),
  (.succeeded, false, true, false, true, .endStreak),
  (.succeeded, true, true, false, false, .nothing),
  (.stopped, true, true, true, false, .nothing),
  (.stopped, true, true, false, false, .nothing),
])
func failureNoticeStep(
  outcome: BackupRunOutcome, scheduled: Bool, notifies: Bool, streakNotified: Bool, noticePending: Bool,
  step: FailureNoticeStep
) {
  #expect(
    FailureNoticeStep.after(
      outcome, scheduled: scheduled, notifies: notifies, streakNotified: streakNotified,
      noticePending: noticePending) == step)
}

@Test func theNotifiedStreakSurvivesARelaunch() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  config.failureNotifiedAt = now
  config.notificationPermissionRequestedAt = now
  config.failureNotificationsEnabled = false
  config.failureNotificationHintDismissedAt = now
  try store.save(config)

  let reloaded = try store.load(defaultHost: "ignored", home: "/ignored")
  #expect(reloaded.failureNotifiedAt == now)
  #expect(reloaded.notificationPermissionRequestedAt == now)
  #expect(reloaded.failureNotificationsEnabled == false)
  #expect(reloaded.failureNotificationHintDismissedAt == now)
}

@Test func aNewInstallNotifiesOnFailure() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
  let config = try store.load(defaultHost: "mac", home: "/Users/t")
  #expect(config.notifiesOnFailure)
  #expect(config.shouldRequestNotificationPermission)
  #expect(!config.showsFailureNotificationHint)
}

@Test func aConfigSavedBeforeFailureNotificationsHasNoStreakAndHasNotAskedForPermission() throws {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  config.failureNotifiedAt = now
  config.notificationPermissionRequestedAt = now
  config.failureNotificationHintDismissedAt = now
  var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
  for key in [
    "failureNotifiedAt", "notificationPermissionRequestedAt", "failureNotificationsEnabled",
    "failureNotificationHintDismissedAt",
  ] {
    json.removeValue(forKey: key)
  }
  let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))
  #expect(decoded.failureNotifiedAt == nil)
  #expect(decoded.notificationPermissionRequestedAt == nil)
  #expect(!decoded.notifiesOnFailure)
  #expect(!decoded.shouldRequestNotificationPermission)
  #expect(decoded.showsFailureNotificationHint)
}

@Test func switchingServersStartsANewFailureStreak() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  config.repositoryId = "repo-1"
  config.failureNotifiedAt = now
  config.switchServer(to: AppConfig.devServerURL)
  #expect(config.failureNotifiedAt == nil)
}

@Test func returningToARememberedServerKeepsItsFailureStreak() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  config.repositoryId = "repo-1"
  config.failureNotifiedAt = now
  config.switchServer(to: AppConfig.devServerURL)
  config.switchServer(to: AppConfig.productionServerURL)
  #expect(config.repositoryId == "repo-1")
  #expect(config.failureNotifiedAt == now)
}

@Test func aRememberedRepositorySavedBeforeFailureNotificationsHasNoStreak() throws {
  let json = Data(#"{"id":"repo-1"}"#.utf8)
  #expect(try JSONDecoder().decode(RememberedRepository.self, from: json).failureNotifiedAt == nil)
}

@Test func forgettingARepositoryEndsItsFailureStreak() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  config.repositoryId = "repo-1"
  config.failureNotifiedAt = now
  let forgot = config.forgetRepository(unlessListedIn: [])
  #expect(forgot)
  #expect(config.failureNotifiedAt == nil)
}

@Test func permissionIsAskedOnceAndOnlyForAScheduledBackupWithNotificationsOn() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  #expect(config.shouldRequestNotificationPermission)
  config.schedule = .manual
  #expect(!config.shouldRequestNotificationPermission)
  config.schedule = .hourly
  config.failureNotificationsEnabled = nil
  #expect(!config.shouldRequestNotificationPermission)
  config.failureNotificationsEnabled = true
  config.notificationPermissionRequestedAt = now
  #expect(!config.shouldRequestNotificationPermission)
}

@Test(arguments: [
  (Schedule.hourly, Bool?.none, false, false, true),
  (.daily(hour: 9, minute: 0), false, false, false, true),
  (.manual, nil, false, false, false),
  (.hourly, true, false, false, false),
  (.hourly, nil, true, false, false),
  (.hourly, nil, false, true, false),
])
func theNotificationHint(
  schedule: Schedule, enabled: Bool?, permissionRequested: Bool, dismissed: Bool, shows: Bool
) {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  config.schedule = schedule
  config.failureNotificationsEnabled = enabled
  config.notificationPermissionRequestedAt = permissionRequested ? now : nil
  config.failureNotificationHintDismissedAt = dismissed ? now : nil
  #expect(config.showsFailureNotificationHint == shows)
}

@Test(arguments: [
  (true, NotificationAuthorization?.none, true, false),
  (true, .authorized, true, false),
  (true, .notDetermined, true, false),
  (true, .denied, false, true),
  (false, .authorized, false, false),
  (false, .denied, false, true),
])
func theNotificationToggle(enabled: Bool, authorization: NotificationAuthorization?, isOn: Bool, note: Bool) {
  let toggle = FailureNotificationToggle(enabled: enabled, authorization: authorization)
  #expect(toggle.isOn == isOn)
  #expect(toggle.showsDeniedNote == note)
}

@Test func theProductionServerIsNamedFUTOCloud() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  #expect(config.serverName == "FUTO Cloud")
  config.serverURL = AppConfig.devServerURL
  #expect(config.serverName == "localhost:8081")
}

@Test(arguments: [
  (BackupStatus.complete, BackupRunOutcome.succeeded),
  (.warn, .succeeded),
  (.cancelled, .stopped),
  (.skipped, .stopped),
  (.incomplete, .stopped),
  (.failed, .failed(.other)),
])
func runRecordOutcome(status: BackupStatus, outcome: BackupRunOutcome) {
  #expect(BackupRunOutcome(record: record(status)) == outcome)
}

@Test func aFailedRunWhoseTokenTheProxyRejectedIsSignedOut() {
  let message =
    #"restic(code: 1, message: "Fatal: unable to open config file: unexpected HTTP response (401): 401 Unauthorized")"#
  #expect(BackupRunOutcome(record: record(.failed, message: message)) == .failed(.signedOut))
}

@Test func aFailedRunWhoseTokenTheAPIRejectedIsSignedOut() {
  let message = String(describing: YuccaError.unauthorized)
  #expect(BackupRunOutcome(record: record(.failed, message: message)) == .failed(.signedOut))
}

@Test func aFailedRunThatCouldNotReachTheServerIsUnreachable() {
  let message =
    #"Error Domain=NSURLErrorDomain Code=-1009 "The Internet connection appears to be offline." UserInfo={}"#
  #expect(BackupRunOutcome(record: record(.failed, message: message)) == .failed(.unreachable))
}

@Test(arguments: [
  (#"Error Domain=NSURLErrorDomain Code=-1004 "Could not connect to the server.""#, BackupFailureReason.unreachable),
  (#"URLError(_nsError: Error Domain=NSURLErrorDomain Code=-1001 "(null)")"#, .unreachable),
  (#"Error Domain=NSURLErrorDomain Code=-1011 "bad response""#, .other),
  ("Fatal: unable to open repository: Get \"https://x\": dial tcp: lookup x: no such host", .unreachable),
  ("Fatal: unable to open repository: read: Connection Reset By Peer", .unreachable),
  ("Fatal: wrong password or no key found", .other),
  ("Load(<data/1234>, 0, 0) returned error, retrying: unexpected HTTP response (403): 403 Forbidden", .other),
  ("unauthorized access to /data", .other),
  ("", .other),
])
func failureReasonFromMessage(message: String, reason: BackupFailureReason) {
  #expect(BackupFailureReason(message: message) == reason)
}

@Test func aRunWithoutAMessageHasAnUnknownReason() {
  #expect(BackupFailureReason(message: nil) == .other)
}

@Test(arguments: [
  (EngineError.notLoggedIn as any Error, BackupFailureReason.signedOut),
  (YuccaError.unauthorized, .signedOut),
  (EngineError.missingMasterKey, .missingRecoveryKey),
  (URLError(.notConnectedToInternet), .unreachable),
  (URLError(.cannotFindHost), .unreachable),
  (URLError(.badServerResponse), .other),
  (EngineError.restic(code: 1, message: "dial tcp 1.2.3.4:443: i/o timeout"), .unreachable),
  (EngineError.restic(code: 1, message: "Fatal: repository is locked"), .other),
  (EngineError.noFolders, .other),
])
func failureReasonFromError(error: any Error, reason: BackupFailureReason) {
  #expect(BackupFailureReason(error: error) == reason)
}

@Test func cancellingIsNotAFailure() {
  #expect(BackupRunOutcome(error: CancellationError()) == .stopped)
  #expect(BackupRunOutcome(error: URLError(.cancelled)) == .stopped)
  #expect(BackupRunOutcome(error: EngineError.busy) == .failed(.other))
}

@Test(arguments: [
  (
    BackupFailureReason.unreachable, 7 * 3600.0,
    "FUTO Backups couldn't reach FUTO Cloud. It will try again at 3:00\u{202F}PM."
  ),
  (.unreachable, 24 * 3600.0, "FUTO Backups couldn't reach FUTO Cloud. It will try again tomorrow at 8:00\u{202F}AM."),
  (.other, 3 * 24 * 3600.0, "The backup ran into a problem. It will try again on Monday at 8:00\u{202F}AM."),
  (.other, -60.0, "The backup ran into a problem. It will try again shortly."),
  (.unreachable, 0, "FUTO Backups couldn't reach FUTO Cloud. It will try again shortly."),
  (.signedOut, 3600.0, "You were signed out of FUTO Backups. Sign in again to keep backing up this Mac."),
  (.missingRecoveryKey, 3600.0, "This Mac's recovery key is missing. Enter it again to keep backing up this Mac."),
])
func failureNoticeText(reason: BackupFailureReason, retryIn: TimeInterval, body: String) {
  let notice = notice(reason, retryAt: now.addingTimeInterval(retryIn))
  #expect(notice.title == "Backup didn't finish")
  #expect(notice.body == body)
}

@Test func aFailureWithNoNextRunOmitsTheRetry() {
  #expect(notice(.unreachable, retryAt: nil).body == "FUTO Backups couldn't reach FUTO Cloud.")
}
