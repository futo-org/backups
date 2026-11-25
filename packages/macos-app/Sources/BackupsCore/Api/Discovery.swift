import Foundation

public struct ServerInfo: Codable, Equatable, Sendable {
  public var apiRoot: URL
  public var resticPackSizeMiB: Int
  public var connectionsMath: String

  public init(apiRoot: URL, resticPackSizeMiB: Int = 16, connectionsMath: String = "16") {
    self.apiRoot = apiRoot
    self.resticPackSizeMiB = resticPackSizeMiB
    self.connectionsMath = connectionsMath
  }
}

public struct Discovery: Sendable {
  public static let retryDelays: [Duration] = [.seconds(1), .seconds(3)]

  private let transport: any HTTPTransport
  private let retryDelays: [Duration]
  private let sleep: @Sendable (Duration) async throws -> Void

  public init(
    transport: any HTTPTransport,
    retryDelays: [Duration] = Discovery.retryDelays,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.transport = transport
    self.retryDelays = retryDelays
    self.sleep = sleep
  }

  public var withoutRetries: Discovery {
    Discovery(transport: transport, retryDelays: [], sleep: sleep)
  }

  public func resolve(_ url: URL) async throws -> ServerInfo {
    try requireSecureTransport(url, "server URL")
    let document = try await fetchDocument(at: url)
    if case .string = document["api_root"] {
      return try serverInfo(from: document)
    }
    if case .string(let metaURLString)? = document["meta_url"], let metaURL = URL(string: metaURLString) {
      try requireSecureTransport(metaURL, "meta_url")
      let meta = try await fetchDocument(at: metaURL)
      if case .string = meta["api_root"] {
        return try serverInfo(from: meta)
      }
      throw YuccaError.invalidDiscovery("meta document at \(metaURLString) has no api_root")
    }
    throw YuccaError.invalidDiscovery("document at \(url) has neither api_root nor meta_url")
  }

  private func fetchDocument(at url: URL) async throws -> [String: JSONValue] {
    let response = try await sendRetryingTransientFailures(HTTPRequest(method: "GET", url: url))
    guard response.status != 404 else {
      throw YuccaError.invalidDiscovery("no discovery document at \(url.absoluteString)")
    }
    let checked = try checkedHTTPResponse(response)
    return try decodeJSON([String: JSONValue].self, from: checked.body)
  }

  private func sendRetryingTransientFailures(_ request: HTTPRequest) async throws -> HTTPResponse {
    for delay in retryDelays {
      do {
        return try await transport.send(request)
      } catch let error where ConnectionFailure.isTransient(error) {
        try await sleep(delay)
      }
    }
    return try await transport.send(request)
  }
}

private enum JSONValue: Decodable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .null
    }
  }
}

private let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

private func requireSecureTransport(_ url: URL, _ name: String) throws {
  switch url.scheme?.lowercased() {
  case "https":
    return
  case "http" where loopbackHosts.contains(url.host(percentEncoded: false)?.lowercased() ?? ""):
    return
  case "http":
    throw YuccaError.insecureDiscovery("\(name) \(url.absoluteString) must use https")
  default:
    throw YuccaError.invalidDiscovery("\(name) \(url.absoluteString) is not a valid http(s) URL")
  }
}

private func serverInfo(from document: [String: JSONValue]) throws -> ServerInfo {
  guard case .string(let apiRootString)? = document["api_root"], let apiRoot = URL(string: apiRootString) else {
    throw YuccaError.invalidDiscovery("meta document api_root is not a valid http(s) URL")
  }
  try requireSecureTransport(apiRoot, "api_root")
  var resticPackSizeMiB = 16
  var connectionsMath = "16"
  if case .object(let config)? = document["config"] {
    if case .number(let value)? = config["restic_pack_size_mib"], let packSize = Int(exactly: value),
      (1...ResticContext.packSizeRangeMiB.upperBound).contains(packSize)
    {
      resticPackSizeMiB = packSize
    }
    if case .string(let value)? = config["connections_math"] {
      connectionsMath = value
    }
  }
  return ServerInfo(apiRoot: apiRoot, resticPackSizeMiB: resticPackSizeMiB, connectionsMath: connectionsMath)
}
