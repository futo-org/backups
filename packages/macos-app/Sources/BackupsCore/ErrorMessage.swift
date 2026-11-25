import Foundation

public enum ConnectionFailure: CaseIterable, Equatable, Sendable {
  case unreachable
  case unavailable
  case offline
  case insecure

  public init?(error: any Error) {
    switch urlErrorCode(in: error) {
    case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost:
      self = .unreachable
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
      self = .offline
    case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
      .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
      .clientCertificateRequired:
      self = .insecure
    default:
      return nil
    }
  }

  public init?(message: String) {
    guard let failure = Self.allCases.first(where: { $0.produced(message) }) else { return nil }
    self = failure
  }

  public init?(resticError: String) {
    if resticError.contains(resticUnavailableStatus) {
      self = .unavailable
      return
    }
    guard resticProxyUnreachableStatuses.contains(where: resticError.contains) else { return nil }
    self = .unreachable
  }

  public static func isTransient(_ error: any Error) -> Bool {
    switch urlErrorCode(in: error) {
    case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: true
    default: false
    }
  }

  public func message(server: String) -> String {
    switch self {
    case .unreachable:
      "Couldn't reach \(server). Check your internet connection and try again."
    case .unavailable:
      "\(server) didn't respond. Check your internet connection, or try again later."
    case .offline:
      "You're offline. Connect to the internet and try again."
    case .insecure:
      "Couldn't connect securely to \(server). Check your network and your Mac's date and time, then try again."
    }
  }

  private func produced(_ message: String) -> Bool {
    let marker = "\u{0}"
    let parts = self.message(server: marker).components(separatedBy: marker)
    guard parts.count == 2 else { return message == parts[0] }
    return message.count > parts[0].count + parts[1].count && message.hasPrefix(parts[0])
      && message.hasSuffix(parts[1])
  }
}

public enum ErrorMessage {
  public static let sessionExpired = "Session expired, sign in again"

  public static func isCancellation(_ error: any Error) -> Bool {
    error is CancellationError || urlErrorCode(in: error) == .cancelled
  }

  public static func signsOut(_ error: any Error) -> Bool {
    switch error {
    case YuccaError.unauthorized: true
    case let incomplete as RestoreIncomplete: signsOut(incomplete.cause)
    default: false
    }
  }

  public static func text(for error: any Error, server: String) -> String? {
    guard !isCancellation(error) else { return nil }
    switch error {
    case let engineError as EngineError:
      return engineErrorText(engineError, server: server)
    case let loginError as DeviceLoginError:
      return loginError.message(server: server)
    case let incomplete as RestoreIncomplete:
      return restoreIncompleteText(incomplete, server: server)
    default:
      return ConnectionFailure(error: error)?.message(server: server) ?? error.localizedDescription
    }
  }

  public static func resticText(_ message: String, server: String) -> String {
    ConnectionFailure(resticError: message)?.message(server: server) ?? message
  }

  private static func engineErrorText(_ error: EngineError, server: String) -> String {
    switch error {
    case .notLoggedIn: "Not signed in"
    case .noRepository: "No repository yet"
    case .noFolders: "No folders selected"
    case .busy: "Another operation is running"
    case .missingMasterKey: "This Mac's recovery key is missing"
    case .restic(_, let message): resticText(message, server: server)
    }
  }

  private static func restoreIncompleteText(_ incomplete: RestoreIncomplete, server: String) -> String {
    var parts = [text(for: incomplete.cause, server: server) ?? "Restore cancelled"]
    let count = incomplete.restored.count
    if count > 0 {
      parts.append(
        count == 1 ? "1 item was restored before it stopped" : "\(count) items were restored before it stopped")
    }
    if let leftover = incomplete.leftoverStaging {
      parts.append("The temporary folder \(leftover.path) couldn't be removed")
    }
    return parts.joined(separator: ". ")
  }
}

extension YuccaError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidDiscovery: "The server address doesn't point to a FUTO Backups server. Check the address."
    case .insecureDiscovery: "The server address must use HTTPS."
    case .unauthorized: ErrorMessage.sessionExpired
    case .http(let status, _) where status >= 500 || [408, 429].contains(status):
      "The server returned an error (HTTP \(status)). Try again later."
    case .http(let status, _): "The server returned an error (HTTP \(status))."
    case .decoding: "The server sent a response FUTO Backups couldn't read."
    }
  }
}

extension DiskSnapshotError: LocalizedError {
  public var errorDescription: String? { description }
}

extension CloudOnlyError: LocalizedError {
  public var errorDescription: String? { description }
}

extension RepositoryKeysError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidMasterKey: "That recovery key isn't valid. Check it and try again."
    }
  }
}

extension SecretStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .keychain(let status): "Couldn't use the keychain (error \(status))."
    }
  }
}

extension ResticProxyError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .spawnFailed, .notReady: "The backup helper couldn't start. Try again, or reinstall FUTO Backups."
    }
  }
}

private let resticProxyUnreachableStatuses = ["unexpected HTTP response (502)", "unexpected HTTP response (504)"]
private let resticUnavailableStatus = "unexpected HTTP response (503)"

func urlErrorCode(in error: any Error) -> URLError.Code? {
  var current: NSError? = error as NSError
  for _ in 0..<8 {
    guard let nsError = current else { return nil }
    if nsError.domain == NSURLErrorDomain {
      return URLError.Code(rawValue: nsError.code)
    }
    current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
  }
  return nil
}
