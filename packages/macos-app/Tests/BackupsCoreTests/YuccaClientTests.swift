import BackupsCore
import Foundation
import Testing

actor StubTransport: HTTPTransport {
  private var responses: [HTTPResponse]
  private(set) var requests: [HTTPRequest] = []

  init(responses: [HTTPResponse] = []) {
    self.responses = responses
  }

  func send(_ request: HTTPRequest) throws -> HTTPResponse {
    requests.append(request)
    guard !responses.isEmpty else {
      throw StubTransportError.responsesExhausted
    }
    return responses.removeFirst()
  }
}

enum StubTransportError: Error {
  case responsesExhausted
}

func jsonResponse(status: Int = 200, _ json: String) -> HTTPResponse {
  HTTPResponse(status: status, body: Data(json.utf8))
}

private let apiRoot = URL(string: "https://server.example/api")!

private enum BodyValue: Decodable, Equatable {
  case bool(Bool)
  case int(Int)
  case string(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else {
      throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON body value")
    }
  }
}

private func singleRequest(_ transport: StubTransport) async throws -> HTTPRequest {
  let requests = await transport.requests
  #expect(requests.count == 1)
  return try #require(requests.first)
}

private func expectBody(_ request: HTTPRequest, _ expected: [String: BodyValue]) throws {
  let data = try #require(request.body)
  let decoded = try JSONDecoder().decode([String: BodyValue].self, from: data)
  #expect(decoded == expected)
}

private func makeClient(_ responses: [HTTPResponse], accessToken: String? = "tok-1") -> (YuccaClient, StubTransport) {
  let transport = StubTransport(responses: responses)
  return (YuccaClient(apiRoot: apiRoot, transport: transport, accessToken: accessToken), transport)
}

private func pollDeviceToken(_ json: String) async throws -> DevicePollResult {
  let (client, _) = makeClient([jsonResponse(json)])
  return try await client.pollDeviceToken(deviceCode: "dc", connectionType: "macos", connectionName: "Mac")
}

@Test func startDeviceAuthorizationRequestAndDecode() async throws {
  let authorizationResponse = """
    {
      "deviceCode": "dc-1",
      "userCode": "AB-CD",
      "verificationUri": "https://server.example/activate",
      "verificationUriComplete": "https://server.example/activate?uc=AB-CD",
      "expiresIn": 600,
      "interval": 5
    }
    """
  let (client, transport) = makeClient([jsonResponse(status: 201, authorizationResponse)])
  let authorization = try await client.startDeviceAuthorization()
  #expect(
    authorization
      == DeviceAuthorization(
        deviceCode: "dc-1",
        userCode: "AB-CD",
        verificationUri: "https://server.example/activate",
        verificationUriComplete: "https://server.example/activate?uc=AB-CD",
        expiresIn: 600,
        interval: 5
      ))
  let request = try await singleRequest(transport)
  #expect(request.method == "POST")
  #expect(request.url == URL(string: "https://server.example/api/auth/oidc/device/authorize"))
  #expect(request.headers.isEmpty)
  #expect(request.body == nil)
}

@Test func startDeviceAuthorizationAcceptsMissingOptionalFields() async throws {
  let (client, _) = makeClient([
    jsonResponse(status: 201, #"{"deviceCode":"dc","userCode":"UC","verificationUri":"https://v","expiresIn":300}"#)
  ])
  let authorization = try await client.startDeviceAuthorization()
  #expect(
    authorization
      == DeviceAuthorization(
        deviceCode: "dc", userCode: "UC", verificationUri: "https://v", expiresIn: 300))
}

@Test func pollDeviceTokenRequest() async throws {
  let (client, transport) = makeClient([jsonResponse(#"{"status":"PENDING"}"#)])
  let result = try await client.pollDeviceToken(
    deviceCode: "dc-1", connectionType: "macos", connectionName: "Alice's Mac")
  #expect(result == .pending)
  let request = try await singleRequest(transport)
  #expect(request.method == "POST")
  #expect(request.url == URL(string: "https://server.example/api/auth/oidc/device/token"))
  #expect(request.headers == ["Content-Type": "application/json"])
  try expectBody(
    request,
    [
      "deviceCode": .string("dc-1"),
      "connectionType": .string("macos"),
      "connectionName": .string("Alice's Mac"),
    ])
}

private let pollCases: [(json: String, expected: DevicePollResult)] = [
  (json: #"{"status":"PENDING"}"#, expected: .pending),
  (json: #"{"status":"SLOW_DOWN"}"#, expected: .slowDown),
  (json: #"{"status":"SUCCESS","accessToken":"tok-9","userId":"u1"}"#, expected: .success(accessToken: "tok-9")),
  (json: #"{"status":"FAILURE"}"#, expected: .failure(reason: "UNKNOWN")),
  (json: #"{"status":"FAILURE","reason":"EMAIL_NOT_ALLOWED"}"#, expected: .failure(reason: "EMAIL_NOT_ALLOWED")),
]

@Test(arguments: pollCases)
func pollDeviceTokenMapsStatus(json: String, expected: DevicePollResult) async throws {
  let result = try await pollDeviceToken(json)
  #expect(result == expected, "response: \(json)")
}

private let pollDecodingFailures: [String] = [
  #"{"status":"SUCCESS"}"#,
  #"{"status":"WHAT"}"#,
  "{}",
]

@Test(arguments: pollDecodingFailures)
func pollDeviceTokenDecodingFailures(json: String) async throws {
  await #expect(throws: YuccaError.self) {
    _ = try await pollDeviceToken(json)
  }
  do {
    _ = try await pollDeviceToken(json)
    Issue.record("expected a decoding error")
  } catch let error as YuccaError {
    switch error {
    case .decoding: break
    default: Issue.record("expected decoding error, got \(error)")
    }
  }
}

@Test(arguments: BackupStatus.allCases)
func submitBackupEndSendsStatusRawValue(status: BackupStatus) async throws {
  let (client, transport) = makeClient([jsonResponse(status: 204, "")])
  try await client.submitBackupEnd(repositoryId: "repo-7", status: status, durationMs: 1234)
  let request = try await singleRequest(transport)
  #expect(request.method == "POST")
  #expect(request.url == URL(string: "https://server.example/api/metrics/submit/repo-7/backup/end"))
  try expectBody(request, ["status": .string(status.rawValue), "durationMs": .int(1234)])
}

@Test func meRequestWithCookie() async throws {
  let (client, transport) = makeClient([
    jsonResponse(
      #"{"id":"user-1","name":"Alice","email":"alice@example.com","sessionId":"s1","connectionId":null,"features":{}}"#)
  ])
  let auth = try await client.me()
  #expect(auth == AuthInfo(id: "user-1", name: "Alice", email: "alice@example.com"))
  let request = try await singleRequest(transport)
  #expect(request.method == "GET")
  #expect(request.url == URL(string: "https://server.example/api/auth"))
  #expect(request.headers == ["Cookie": "yucca-access-token=tok-1"])
}

@Test func meDecodesConnectionIdAndOmitsCookieWithoutToken() async throws {
  let (client, transport) = makeClient(
    [jsonResponse(#"{"id":"u","name":"N","email":"e","connectionId":"conn-1"}"#)], accessToken: nil)
  let auth = try await client.me()
  #expect(auth == AuthInfo(id: "u", name: "N", email: "e", connectionId: "conn-1"))
  let request = try await singleRequest(transport)
  #expect(request.headers.isEmpty)
}

@Test func logoutRequest() async throws {
  let (client, transport) = makeClient([jsonResponse(status: 204, "")])
  try await client.logout()
  let request = try await singleRequest(transport)
  #expect(request.method == "GET")
  #expect(request.url == URL(string: "https://server.example/api/auth/logout"))
  #expect(request.headers == ["Cookie": "yucca-access-token=tok-1"])
  #expect(request.body == nil)
}

@Test func listRepositoriesRequestAndDecode() async throws {
  let body = """
    {
      "repositories": [
        {"id": "r1", "name": "main", "worm": true, "connectionId": "c1",
         "metrics": {"sizeBytes": 1099511627776, "lastBackup": "2026-01-02T03:04:05Z"}},
        {"id": "r2", "name": "aux", "worm": false, "connectionId": null}
      ]
    }
    """
  let (client, transport) = makeClient([jsonResponse(body)])
  let repositories = try await client.listRepositories()
  #expect(
    repositories
      == [
        RemoteRepository(
          id: "r1", name: "main", worm: true, connectionId: "c1", sizeBytes: 1_099_511_627_776,
          lastBackup: "2026-01-02T03:04:05Z"),
        RemoteRepository(id: "r2", name: "aux", worm: false),
      ])
  let request = try await singleRequest(transport)
  #expect(request.method == "GET")
  #expect(request.url == URL(string: "https://server.example/api/repository"))
  #expect(request.headers == ["Cookie": "yucca-access-token=tok-1"])
}

@Test func createRepositoryRequestAndDecode() async throws {
  let (client, transport) = makeClient([
    jsonResponse(status: 201, #"{"repository":{"id":"r9","name":"new-repo","worm":false,"connectionId":"conn-3"}}"#)
  ])
  let repository = try await client.createRepository(name: "new-repo")
  #expect(repository == RemoteRepository(id: "r9", name: "new-repo", worm: false, connectionId: "conn-3"))
  let request = try await singleRequest(transport)
  #expect(request.method == "POST")
  #expect(request.url == URL(string: "https://server.example/api/repository"))
  #expect(request.headers == ["Cookie": "yucca-access-token=tok-1", "Content-Type": "application/json"])
  try expectBody(request, ["name": .string("new-repo"), "worm": .bool(false)])
}

@Test func submitBackupStartRequest() async throws {
  let (client, transport) = makeClient([jsonResponse(status: 204, "")])
  try await client.submitBackupStart(repositoryId: "repo-7")
  let request = try await singleRequest(transport)
  #expect(request.method == "POST")
  #expect(request.url == URL(string: "https://server.example/api/metrics/submit/repo-7/backup/start"))
  #expect(request.headers == ["Cookie": "yucca-access-token=tok-1"])
  #expect(request.body == nil)
}

@Test func submitRepositorySizeRequest() async throws {
  let (client, transport) = makeClient([jsonResponse(status: 204, "")])
  try await client.submitRepositorySize(repositoryId: "repo-7", sizeBytes: 987_654_321_000)
  let request = try await singleRequest(transport)
  #expect(request.method == "PATCH")
  #expect(request.url == URL(string: "https://server.example/api/metrics/submit/repo-7/size"))
  #expect(request.headers == ["Cookie": "yucca-access-token=tok-1", "Content-Type": "application/json"])
  try expectBody(request, ["sizeBytes": .int(987_654_321_000)])
}

@Test func remoteRepositoryDecodingWithAndWithoutMetrics() throws {
  let withMetrics =
    #"{"id":"r1","name":"main","worm":true,"connectionId":"c1","metrics":{"sizeBytes":2048,"lastBackup":"2026-01-01T00:00:00Z"},"extra":1}"#
  let decoded = try JSONDecoder().decode(RemoteRepository.self, from: Data(withMetrics.utf8))
  #expect(
    decoded
      == RemoteRepository(
        id: "r1", name: "main", worm: true, connectionId: "c1", sizeBytes: 2048,
        lastBackup: "2026-01-01T00:00:00Z"))
  let withoutMetrics = #"{"id":"r2","name":"aux","worm":false,"connectionId":null}"#
  #expect(
    try JSONDecoder().decode(RemoteRepository.self, from: Data(withoutMetrics.utf8))
      == RemoteRepository(id: "r2", name: "aux", worm: false))
}

@Test func unauthorizedMapsToUnauthorized() async throws {
  let (client, _) = makeClient([jsonResponse(status: 401, #"{"error":"nope"}"#)])
  await #expect(throws: YuccaError.unauthorized) {
    _ = try await client.me()
  }
}

@Test func non2xxMapsToHttpErrorWithBody() async throws {
  let (client, _) = makeClient([jsonResponse(status: 500, "boom")])
  await #expect(throws: YuccaError.http(status: 500, body: "boom")) {
    _ = try await client.listRepositories()
  }
}

@Test func httpErrorBodyIsTruncatedTo500Characters() async throws {
  let long = String(repeating: "x", count: 600)
  let (client, _) = makeClient([HTTPResponse(status: 418, body: Data(long.utf8))])
  do {
    _ = try await client.logout()
    Issue.record("expected http error")
  } catch let error as YuccaError {
    switch error {
    case .http(let status, let body):
      #expect(status == 418)
      #expect(body.count == 500)
    default: Issue.record("expected http error, got \(error)")
    }
  }
}
