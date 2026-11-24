import Foundation

public enum BackupFailureReason: Equatable, Sendable {
  case unreachable
  case signedOut
  case missingRecoveryKey
  case other

  private static let unreachableURLErrorCodes: Set<Int> = [
    NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
    NSURLErrorDNSLookupFailed, NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff,
    NSURLErrorDataNotAllowed, NSURLErrorSecureConnectionFailed,
  ]

  private static let unreachableResticPhrases = [
    "dial tcp", "no such host", "connection refused", "network is unreachable", "i/o timeout",
    "tls handshake timeout", "connection reset by peer", "no route to host",
  ]

  public init(error: any Error) {
    switch error {
    case EngineError.notLoggedIn, YuccaError.unauthorized:
      self = .signedOut
    case EngineError.missingMasterKey:
      self = .missingRecoveryKey
    case let urlError as URLError where Self.unreachableURLErrorCodes.contains(urlError.errorCode):
      self = .unreachable
    case EngineError.restic(_, let message):
      self.init(message: message)
    default:
      self.init(message: String(describing: error))
    }
  }

  public init(message: String?) {
    guard let message else {
      self = .other
      return
    }
    if let code = Self.urlErrorCode(in: message), Self.unreachableURLErrorCodes.contains(code) {
      self = .unreachable
      return
    }
    let lowered = message.lowercased()
    self = Self.unreachableResticPhrases.contains(where: lowered.contains) ? .unreachable : .other
  }

  private static func urlErrorCode(in message: String) -> Int? {
    guard let marker = message.range(of: "NSURLErrorDomain Code=") else { return nil }
    return Int(message[marker.upperBound...].prefix { $0 == "-" || $0.isNumber })
  }
}

public enum BackupRunOutcome: Equatable, Sendable {
  case succeeded
  case failed(BackupFailureReason)
  case stopped

  public init(record: RunRecord) {
    switch record.status {
    case .complete, .warn: self = .succeeded
    case .failed: self = .failed(BackupFailureReason(message: record.message))
    case .incomplete, .cancelled, .skipped: self = .stopped
    }
  }

  public init(error: any Error) {
    self = error is CancellationError ? .stopped : .failed(BackupFailureReason(error: error))
  }
}

public struct FailureNotificationDecision: Equatable, Sendable {
  public var notify: Bool
  public var streakNotified: Bool

  public init(notify: Bool, streakNotified: Bool) {
    self.notify = notify
    self.streakNotified = streakNotified
  }

  public static func after(_ outcome: BackupRunOutcome, scheduled: Bool, streakNotified: Bool) -> Self {
    switch outcome {
    case .succeeded:
      return Self(notify: false, streakNotified: false)
    case .failed where scheduled && !streakNotified:
      return Self(notify: true, streakNotified: true)
    case .failed, .stopped:
      return Self(notify: false, streakNotified: streakNotified)
    }
  }
}

public struct FailureNotice: Equatable, Sendable {
  public var title: String
  public var body: String

  public init(title: String, body: String) {
    self.title = title
    self.body = body
  }

  public static let title = "Backup didn't finish"

  public init(
    reason: BackupFailureReason, server: String, retryAt: Date?, now: Date, calendar: Calendar, locale: Locale
  ) {
    let retry = retryAt.flatMap { Self.retrySentence(at: $0, now: now, calendar: calendar, locale: locale) }
    let body: String
    switch reason {
    case .unreachable:
      body = ["FUTO Backups couldn't reach \(server).", retry].compactMap { $0 }.joined(separator: " ")
    case .signedOut:
      body = "You were signed out of FUTO Backups. Sign in again to keep backing up this Mac."
    case .missingRecoveryKey:
      body = "This Mac's recovery key is missing. Enter it again to keep backing up this Mac."
    case .other:
      body = ["The backup ran into a problem.", retry].compactMap { $0 }.joined(separator: " ")
    }
    self.init(title: Self.title, body: body)
  }

  private static func retrySentence(at date: Date, now: Date, calendar: Calendar, locale: Locale) -> String? {
    guard date > now else { return nil }
    let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    let time = date.formatted(style.hour().minute())
    if calendar.isDate(date, inSameDayAs: now) {
      return "It will try again at \(time)."
    }
    guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
    if calendar.isDate(date, inSameDayAs: tomorrow) {
      return "It will try again tomorrow at \(time)."
    }
    return "It will try again on \(date.formatted(style.weekday(.wide))) at \(time)."
  }
}

extension AppConfig {
  public var serverName: String {
    serverURL == Self.productionServerURL ? "FUTO Cloud" : serverDisplayName
  }

  public var shouldRequestNotificationPermission: Bool {
    notificationPermissionRequestedAt == nil && schedule != .manual
  }

  public mutating func noteBackupOutcome(_ outcome: BackupRunOutcome, scheduled: Bool, at date: Date) -> Bool {
    let decision = FailureNotificationDecision.after(
      outcome, scheduled: scheduled, streakNotified: failureNotifiedAt != nil)
    if !decision.streakNotified {
      failureNotifiedAt = nil
    } else if failureNotifiedAt == nil {
      failureNotifiedAt = date
    }
    return decision.notify
  }
}
