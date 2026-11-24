import Foundation

public struct DeviceAuthorization: Codable, Equatable, Sendable {
  public var deviceCode: String
  public var userCode: String
  public var verificationUri: String
  public var verificationUriComplete: String?
  public var expiresIn: Int
  public var interval: Int?

  public init(
    deviceCode: String,
    userCode: String,
    verificationUri: String,
    verificationUriComplete: String? = nil,
    expiresIn: Int,
    interval: Int? = nil
  ) {
    self.deviceCode = deviceCode
    self.userCode = userCode
    self.verificationUri = verificationUri
    self.verificationUriComplete = verificationUriComplete
    self.expiresIn = expiresIn
    self.interval = interval
  }
}

public enum DevicePollResult: Equatable, Sendable {
  case pending
  case slowDown
  case success(accessToken: String)
  case failure(reason: String)
}

public struct AuthInfo: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var email: String
  public var connectionId: String?

  public init(id: String, name: String, email: String, connectionId: String? = nil) {
    self.id = id
    self.name = name
    self.email = email
    self.connectionId = connectionId
  }
}

public struct RemoteRepository: Codable, Equatable, Sendable, Identifiable {
  public var id: String
  public var name: String
  public var worm: Bool
  public var connectionId: String?
  public var sizeBytes: Int64?
  public var lastBackup: String?
  public var connectionType: String?

  public init(
    id: String,
    name: String,
    worm: Bool,
    connectionId: String? = nil,
    sizeBytes: Int64? = nil,
    lastBackup: String? = nil,
    connectionType: String? = nil
  ) {
    self.id = id
    self.name = name
    self.worm = worm
    self.connectionId = connectionId
    self.sizeBytes = sizeBytes
    self.lastBackup = lastBackup
    self.connectionType = connectionType
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, worm, connectionId, metrics, connectionType
  }

  private enum MetricsKeys: String, CodingKey {
    case sizeBytes, lastBackup
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    worm = try container.decode(Bool.self, forKey: .worm)
    connectionId = try container.decodeIfPresent(String.self, forKey: .connectionId)
    connectionType = try container.decodeIfPresent(String.self, forKey: .connectionType)
    sizeBytes = nil
    lastBackup = nil
    if let metrics = try? container.nestedContainer(keyedBy: MetricsKeys.self, forKey: .metrics) {
      sizeBytes = try metrics.decodeIfPresent(Int64.self, forKey: .sizeBytes)
      lastBackup = try metrics.decodeIfPresent(String.self, forKey: .lastBackup)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(worm, forKey: .worm)
    try container.encodeIfPresent(connectionId, forKey: .connectionId)
    try container.encodeIfPresent(connectionType, forKey: .connectionType)
    if sizeBytes != nil || lastBackup != nil {
      var metrics = container.nestedContainer(keyedBy: MetricsKeys.self, forKey: .metrics)
      try metrics.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
      try metrics.encodeIfPresent(lastBackup, forKey: .lastBackup)
    }
  }
}

public enum TicketAction: String, Encodable, Sendable {
  case deleteRepository = "repository.delete"
}

public protocol YuccaRepositoryAPI: Sendable {
  func listRepositories() async throws -> [RemoteRepository]
  func createRepository(name: String) async throws -> RemoteRepository
  func submitBackupStart(repositoryId: String) async throws
  func submitBackupEnd(repositoryId: String, status: BackupStatus, durationMs: Int) async throws
  func submitRepositorySize(repositoryId: String, sizeBytes: Int64) async throws
  func submitStructuredLog(_ log: StructuredLog) async throws
}

public struct YuccaClient: YuccaRepositoryAPI {
  public let apiRoot: URL
  public let accessToken: String?
  private let transport: any HTTPTransport

  public init(apiRoot: URL, transport: any HTTPTransport, accessToken: String? = nil) {
    self.apiRoot = apiRoot
    self.transport = transport
    self.accessToken = accessToken
  }

  public func withAccessToken(_ token: String) -> YuccaClient {
    YuccaClient(apiRoot: apiRoot, transport: transport, accessToken: token)
  }

  public func startDeviceAuthorization() async throws -> DeviceAuthorization {
    let response = try await send(method: "POST", path: "auth/oidc/device/authorize", sendsCookie: false)
    return try decodeJSON(DeviceAuthorization.self, from: response.body)
  }

  public func pollDeviceToken(
    deviceCode: String,
    connectionType: String,
    connectionName: String
  ) async throws -> DevicePollResult {
    let body = try encodeJSON(
      DeviceTokenRequest(deviceCode: deviceCode, connectionType: connectionType, connectionName: connectionName))
    let response = try await send(method: "POST", path: "auth/oidc/device/token", body: body, sendsCookie: false)
    let payload = try decodeJSON(DevicePollPayload.self, from: response.body)
    switch payload.status {
    case "PENDING":
      return .pending
    case "SLOW_DOWN":
      return .slowDown
    case "SUCCESS":
      guard let accessToken = payload.accessToken else {
        throw YuccaError.decoding("SUCCESS device poll response without accessToken")
      }
      return .success(accessToken: accessToken)
    case "FAILURE":
      return .failure(reason: payload.reason ?? "UNKNOWN")
    default:
      throw YuccaError.decoding("unknown device poll status: \(payload.status)")
    }
  }

  public func me() async throws -> AuthInfo {
    let response = try await send(method: "GET", path: "auth")
    return try decodeJSON(AuthInfo.self, from: response.body)
  }

  public func logout() async throws {
    _ = try await send(method: "GET", path: "auth/logout")
  }

  public func listRepositories() async throws -> [RemoteRepository] {
    let response = try await send(method: "GET", path: "repository")
    return try decodeJSON(RepositoryListPayload.self, from: response.body).repositories
  }

  public func createRepository(name: String) async throws -> RemoteRepository {
    let body = try encodeJSON(CreateRepositoryRequest(name: name, worm: false))
    let response = try await send(method: "POST", path: "repository", body: body)
    return try decodeJSON(RepositoryPayload.self, from: response.body).repository
  }

  public func createTicket(action: TicketAction, repositoryId: String) async throws -> URL {
    let body = try encodeJSON(TicketRequest(action: action, repositoryId: repositoryId))
    let response = try await send(method: "POST", path: "auth/ticket", body: body)
    let redirectTo = try decodeJSON(TicketPayload.self, from: response.body).redirectTo
    guard let url = URL(string: redirectTo), url.scheme == "https" || url.scheme == "http" else {
      throw YuccaError.decoding("ticket redirect is not a web URL")
    }
    return url
  }

  public func deleteConnection(id: String) async throws {
    _ = try await send(method: "DELETE", path: "connections/\(id)")
  }

  public func submitBackupStart(repositoryId: String) async throws {
    _ = try await send(method: "POST", path: "metrics/submit/\(repositoryId)/backup/start")
  }

  public func submitBackupEnd(repositoryId: String, status: BackupStatus, durationMs: Int) async throws {
    let body = try encodeJSON(BackupEndRequest(status: status.rawValue, durationMs: durationMs))
    _ = try await send(method: "POST", path: "metrics/submit/\(repositoryId)/backup/end", body: body)
  }

  public func submitRepositorySize(repositoryId: String, sizeBytes: Int64) async throws {
    let body = try encodeJSON(RepositorySizeRequest(sizeBytes: sizeBytes))
    _ = try await send(method: "PATCH", path: "metrics/submit/\(repositoryId)/size", body: body)
  }

  public func submitStructuredLog(_ log: StructuredLog) async throws {
    let body = try encodeJSON(log)
    _ = try await send(method: "POST", path: "metrics/submit/log", body: body)
  }

  private func send(method: String, path: String, body: Data? = nil, sendsCookie: Bool = true) async throws
    -> HTTPResponse
  {
    var headers: [String: String] = [:]
    if sendsCookie, let accessToken {
      headers["Cookie"] = "yucca-access-token=\(accessToken)"
    }
    if body != nil {
      headers["Content-Type"] = "application/json"
    }
    let request = HTTPRequest(method: method, url: apiRoot.appending(path: path), headers: headers, body: body)
    let response = try await transport.send(request)
    return try checkedHTTPResponse(response)
  }
}

private struct DeviceTokenRequest: Encodable {
  var deviceCode: String
  var connectionType: String
  var connectionName: String
}

private struct DevicePollPayload: Decodable {
  var status: String
  var accessToken: String?
  var reason: String?
}

private struct CreateRepositoryRequest: Encodable {
  var name: String
  var worm: Bool
}

private struct TicketRequest: Encodable {
  var action: TicketAction
  var repositoryId: String
}

private struct TicketPayload: Decodable {
  var redirectTo: String
}

private struct RepositoryListPayload: Decodable {
  var repositories: [RemoteRepository]
}

private struct RepositoryPayload: Decodable {
  var repository: RemoteRepository
}

private struct BackupEndRequest: Encodable {
  var status: String
  var durationMs: Int
}

private struct RepositorySizeRequest: Encodable {
  var sizeBytes: Int64
}
