import BackupsCore
import Foundation
import Testing

private let apiRoot = URL(string: "https://server.example/api")!
private let wellKnownURL = URL(string: "https://server.example/.well-known/futo-backups")!
private let metaURL = URL(string: "https://server.example/.well-known/futo-backups/meta")!

private func resolve(_ url: URL, responses: [HTTPResponse]) async throws -> (ServerInfo, StubTransport) {
  let transport = StubTransport(responses: responses)
  let info = try await Discovery(transport: transport).resolve(url)
  return (info, transport)
}

private func expectInvalidDiscovery(_ url: URL, responses: [HTTPResponse]) async throws {
  let transport = StubTransport(responses: responses)
  do {
    _ = try await Discovery(transport: transport).resolve(url)
    Issue.record("expected invalidDiscovery")
  } catch let error as YuccaError {
    switch error {
    case .invalidDiscovery: break
    default: Issue.record("expected invalidDiscovery, got \(error)")
    }
  }
}

@Test func wellKnownResolvesThroughMetaWithTwoGetRequests() async throws {
  let (info, transport) = try await resolve(
    wellKnownURL,
    responses: [
      jsonResponse(#"{"product":"futo-backups","meta_url":"\#(metaURL.absoluteString)"}"#),
      jsonResponse(
        #"{"api_root":"\#(apiRoot.absoluteString)","config":{"restic_pack_size_mib":32,"connections_math":"8"}}"#),
    ])
  #expect(info == ServerInfo(apiRoot: apiRoot, resticPackSizeMiB: 32, connectionsMath: "8"))
  let requests = await transport.requests
  #expect(requests.count == 2)
  #expect(requests[0].method == "GET")
  #expect(requests[0].url == wellKnownURL)
  #expect(requests[0].headers.isEmpty)
  #expect(requests[0].body == nil)
  #expect(requests[1].method == "GET")
  #expect(requests[1].url == metaURL)
  #expect(requests[1].headers.isEmpty)
  #expect(requests[1].body == nil)
}

@Test func directMetaURLResolvesWithOneGetRequest() async throws {
  let (info, transport) = try await resolve(
    metaURL,
    responses: [jsonResponse(#"{"api_root":"\#(apiRoot.absoluteString)","config":{"restic_pack_size_mib":64}}"#)])
  #expect(info == ServerInfo(apiRoot: apiRoot, resticPackSizeMiB: 64, connectionsMath: "16"))
  let requests = await transport.requests
  #expect(requests.count == 1)
  #expect(requests[0].url == metaURL)
}

@Test func metaWithoutConfigUsesDefaults() async throws {
  let (info, _) = try await resolve(metaURL, responses: [jsonResponse(#"{"api_root":"\#(apiRoot.absoluteString)"}"#)])
  #expect(info == ServerInfo(apiRoot: apiRoot, resticPackSizeMiB: 16, connectionsMath: "16"))
}

@Test(arguments: [
  ("1", 1), ("4", 4), ("128", 128), ("32.0", 32), ("32.5", 16), ("0", 16), ("-8", 16), ("129", 16),
  ("1e300", 16), (#""32""#, 16), ("null", 16),
])
func packSizeAcceptsOnlyWholeMebibytesWithinResticLimits(json: String, expected: Int) async throws {
  let (info, _) = try await resolve(
    metaURL,
    responses: [jsonResponse(#"{"api_root":"\#(apiRoot.absoluteString)","config":{"restic_pack_size_mib":\#(json)}}"#)])
  #expect(info.resticPackSizeMiB == expected)
}

@Test func documentWithoutApiRootOrMetaURLIsInvalidDiscovery() async throws {
  try await expectInvalidDiscovery(wellKnownURL, responses: [jsonResponse(#"{"product":"futo-backups"}"#)])
}

@Test func metaWithoutApiRootIsInvalidDiscovery() async throws {
  try await expectInvalidDiscovery(
    wellKnownURL,
    responses: [
      jsonResponse(#"{"meta_url":"\#(metaURL.absoluteString)"}"#),
      jsonResponse(#"{"config":{"restic_pack_size_mib":8}}"#),
    ])
}

@Test func invalidApiRootIsInvalidDiscovery() async throws {
  try await expectInvalidDiscovery(metaURL, responses: [jsonResponse(#"{"api_root":"not a url"}"#)])
  try await expectInvalidDiscovery(metaURL, responses: [jsonResponse(#"{"api_root":"notaurl"}"#)])
  try await expectInvalidDiscovery(metaURL, responses: [jsonResponse(#"{"api_root":null}"#)])
}

@Test(arguments: [
  "http://localhost:3020/.well-known/futo-backups", "http://LOCALHOST/meta", "http://127.0.0.1:8080/meta",
  "http://[::1]:3020/meta", "HTTPS://server.example/meta",
])
func httpsOrLoopbackHttpIsAcceptedAtEveryHop(url: String) async throws {
  let local = try #require(URL(string: url))
  let (info, transport) = try await resolve(
    local,
    responses: [
      jsonResponse(#"{"meta_url":"\#(url)"}"#),
      jsonResponse(#"{"api_root":"\#(url)/api"}"#),
    ])
  #expect(info.apiRoot.absoluteString == "\(url)/api")
  #expect(await transport.requests.map(\.url) == [local, local])
}

@Test(arguments: [
  "http://server.example/.well-known/futo-backups", "http://localhost.evil.example/meta", "http://127.0.0.2/meta",
  "http://10.0.0.1/meta", "ftp://server.example/meta",
])
func plainHttpToAnotherHostIsRejectedBeforeAnyRequest(url: String) async throws {
  let transport = StubTransport(responses: [])
  await #expect(throws: YuccaError.self) {
    _ = try await Discovery(transport: transport).resolve(try #require(URL(string: url)))
  }
  #expect(await transport.requests.isEmpty)
}

@Test func plainHttpMetaURLIsRejectedBeforeFollowingIt() async throws {
  let transport = StubTransport(responses: [jsonResponse(#"{"meta_url":"http://server.example/meta"}"#)])
  await #expect(throws: YuccaError.invalidDiscovery("meta_url http://server.example/meta must use https")) {
    _ = try await Discovery(transport: transport).resolve(wellKnownURL)
  }
  #expect(await transport.requests.count == 1)
}

@Test func plainHttpApiRootIsRejected() async throws {
  await #expect(throws: YuccaError.invalidDiscovery("api_root http://server.example/api must use https")) {
    _ = try await resolve(metaURL, responses: [jsonResponse(#"{"api_root":"http://server.example/api"}"#)])
  }
}

@Test func non2xxStatusBecomesHttpError() async throws {
  let transport = StubTransport(responses: [HTTPResponse(status: 503, body: Data("down".utf8))])
  await #expect(throws: YuccaError.http(status: 503, body: "down")) {
    _ = try await Discovery(transport: transport).resolve(wellKnownURL)
  }
}

@Test func unauthorizedStatusBecomesUnauthorizedError() async throws {
  let transport = StubTransport(responses: [jsonResponse(status: 401, #"{"error":"no"}"#)])
  await #expect(throws: YuccaError.unauthorized) {
    _ = try await Discovery(transport: transport).resolve(wellKnownURL)
  }
}

@Test func malformedJsonBecomesDecodingError() async throws {
  let transport = StubTransport(responses: [HTTPResponse(status: 200, body: Data("<html>".utf8))])
  await #expect(throws: YuccaError.self) {
    _ = try await Discovery(transport: transport).resolve(wellKnownURL)
  }
}
