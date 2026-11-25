import Foundation

public enum DeviceLoginError: Error, Equatable, Sendable {
  case failed(reason: String)
  case expired

  public func message(server: String) -> String {
    switch self {
    case .expired, .failed(reason: "EXPIRED"):
      return "The sign-in code expired. Try again."
    case .failed(reason: "ACCESS_DENIED"):
      return "You declined the sign-in in your browser."
    case .failed(reason: "EMAIL_NOT_ALLOWED"):
      return "This account cannot use FUTO Backups yet."
    case .failed(reason: "FEATURE_NOT_ENABLED"):
      return "Mac backups are not enabled for this account."
    case .failed(reason: "UNSUPPORTED_CONNECTION_TYPE"):
      return "\(server) does not support the Mac app yet."
    case .failed(reason: "UNKNOWN"):
      return "\(server) could not finish signing in this Mac. It possibly does not support the Mac app yet."
    case .failed(let reason):
      return "Sign-in failed (\(reason))."
    }
  }
}

public struct DeviceLogin: Sendable {
  private let client: YuccaClient
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    client: YuccaClient,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.client = client
    self.sleep = sleep
  }

  public func waitForToken(
    _ authorization: DeviceAuthorization,
    connectionType: String,
    connectionName: String
  ) async throws -> String {
    var interval = authorization.interval ?? 5
    var elapsed = 0
    while true {
      if elapsed >= authorization.expiresIn {
        throw DeviceLoginError.expired
      }
      try await sleep(.seconds(interval))
      elapsed += interval
      let result = try await client.pollDeviceToken(
        deviceCode: authorization.deviceCode,
        connectionType: connectionType,
        connectionName: connectionName
      )
      switch result {
      case .pending:
        continue
      case .slowDown:
        interval += 5
      case .success(let accessToken):
        return accessToken
      case .failure(let reason):
        throw DeviceLoginError.failed(reason: reason)
      }
    }
  }
}
