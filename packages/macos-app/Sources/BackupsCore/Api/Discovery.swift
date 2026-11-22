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
  private let transport: any HTTPTransport

  public init(transport: any HTTPTransport) {
    self.transport = transport
  }

  public func resolve(_ url: URL) async throws -> ServerInfo {
    let document = try await fetchDocument(at: url)
    if case .string = document["api_root"] {
      return try serverInfo(from: document)
    }
    if case .string(let metaURLString)? = document["meta_url"], let metaURL = URL(string: metaURLString) {
      let meta = try await fetchDocument(at: metaURL)
      if case .string = meta["api_root"] {
        return try serverInfo(from: meta)
      }
      throw YuccaError.invalidDiscovery("meta document at \(metaURLString) has no api_root")
    }
    throw YuccaError.invalidDiscovery("document at \(url) has neither api_root nor meta_url")
  }

  private func fetchDocument(at url: URL) async throws -> [String: JSONValue] {
    let response = try await transport.send(HTTPRequest(method: "GET", url: url))
    let checked = try checkedHTTPResponse(response)
    return try decodeJSON([String: JSONValue].self, from: checked.body)
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

private func serverInfo(from document: [String: JSONValue]) throws -> ServerInfo {
  guard case .string(let apiRootString)? = document["api_root"],
    let apiRoot = URL(string: apiRootString),
    let scheme = apiRoot.scheme?.lowercased(),
    scheme == "http" || scheme == "https"
  else {
    throw YuccaError.invalidDiscovery("meta document api_root is not a valid http(s) URL")
  }
  var resticPackSizeMiB = 16
  var connectionsMath = "16"
  if case .object(let config)? = document["config"] {
    if case .number(let value)? = config["restic_pack_size_mib"] {
      resticPackSizeMiB = Int(value)
    }
    if case .string(let value)? = config["connections_math"] {
      connectionsMath = value
    }
  }
  return ServerInfo(apiRoot: apiRoot, resticPackSizeMiB: resticPackSizeMiB, connectionsMath: connectionsMath)
}
