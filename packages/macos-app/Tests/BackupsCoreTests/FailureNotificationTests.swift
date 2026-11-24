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
  (BackupRunOutcome.failed(.unreachable), true, false, true, true),
  (.failed(.other), true, true, false, true),
  (.failed(.signedOut), false, false, false, false),
  (.failed(.other), false, true, false, true),
  (.succeeded, true, true, false, false),
  (.succeeded, false, true, false, false),
  (.succeeded, true, false, false, false),
  (.stopped, true, true, false, true),
  (.stopped, false, false, false, false),
])
func failureNotificationDecision(
  outcome: BackupRunOutcome, scheduled: Bool, streakNotified: Bool, notify: Bool, stillNotified: Bool
) {
  #expect(
    FailureNotificationDecision.after(outcome, scheduled: scheduled, streakNotified: streakNotified)
      == FailureNotificationDecision(notify: notify, streakNotified: stillNotified))
}

@Test func aFailureStreakNotifiesOnceAndASuccessfulBackupStartsANewStreak() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  let failure = BackupRunOutcome.failed(.unreachable)

  let notifies = config.noteBackupOutcome(failure, scheduled: true, at: now)
  #expect(notifies)
  #expect(config.failureNotifiedAt == now)
  let retryNotifies = config.noteBackupOutcome(failure, scheduled: true, at: now.addingTimeInterval(60))
  #expect(!retryNotifies)
  #expect(config.failureNotifiedAt == now)

  let successNotifies = config.noteBackupOutcome(.succeeded, scheduled: false, at: now.addingTimeInterval(120))
  #expect(!successNotifies)
  #expect(config.failureNotifiedAt == nil)

  let nextStreakNotifies = config.noteBackupOutcome(failure, scheduled: true, at: now.addingTimeInterval(180))
  #expect(nextStreakNotifies)
}

@Test func aManualFailureNeitherNotifiesNorStartsAStreak() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  let notifies = config.noteBackupOutcome(.failed(.other), scheduled: false, at: now)
  #expect(!notifies)
  #expect(config.failureNotifiedAt == nil)
  let scheduledNotifies = config.noteBackupOutcome(.failed(.other), scheduled: true, at: now)
  #expect(scheduledNotifies)
}

@Test func theNotifiedStreakSurvivesARelaunch() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  _ = config.noteBackupOutcome(.failed(.other), scheduled: true, at: now)
  config.notificationPermissionRequestedAt = now
  try store.save(config)

  var reloaded = try store.load(defaultHost: "ignored", home: "/ignored")
  #expect(reloaded.failureNotifiedAt == now)
  #expect(reloaded.notificationPermissionRequestedAt == now)
  let notifies = reloaded.noteBackupOutcome(.failed(.other), scheduled: true, at: now)
  #expect(!notifies)
}

@Test func aConfigSavedBeforeFailureNotificationsHasNoStreakAndHasNotAskedForPermission() throws {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  config.failureNotifiedAt = now
  config.notificationPermissionRequestedAt = now
  var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any])
  json.removeValue(forKey: "failureNotifiedAt")
  json.removeValue(forKey: "notificationPermissionRequestedAt")
  let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONSerialization.data(withJSONObject: json))
  #expect(decoded.failureNotifiedAt == nil)
  #expect(decoded.notificationPermissionRequestedAt == nil)
}

@Test func switchingServersStartsANewFailureStreak() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  _ = config.noteBackupOutcome(.failed(.other), scheduled: true, at: now)
  config.switchServer(to: AppConfig.devServerURL)
  #expect(config.failureNotifiedAt == nil)
}

@Test func permissionIsAskedOnceAndOnlyForAScheduledBackup() {
  var config = AppConfig.defaults(host: "mac", home: "/Users/t")
  #expect(config.shouldRequestNotificationPermission)
  config.schedule = .manual
  #expect(!config.shouldRequestNotificationPermission)
  config.schedule = .hourly
  config.notificationPermissionRequestedAt = now
  #expect(!config.shouldRequestNotificationPermission)
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
  #expect(BackupRunOutcome(error: EngineError.busy) == .failed(.other))
}

@Test(arguments: [
  (
    BackupFailureReason.unreachable, 7 * 3600.0,
    "FUTO Backups couldn't reach FUTO Cloud. It will try again at 3:00\u{202F}PM."
  ),
  (.unreachable, 24 * 3600.0, "FUTO Backups couldn't reach FUTO Cloud. It will try again tomorrow at 8:00\u{202F}AM."),
  (.other, 3 * 24 * 3600.0, "The backup ran into a problem. It will try again on Monday at 8:00\u{202F}AM."),
  (.other, -60.0, "The backup ran into a problem."),
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
