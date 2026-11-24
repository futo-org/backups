import Foundation

public struct HTTPRequest: Sendable, Equatable {
  public var method: String
  public var url: URL
  public var headers: [String: String]
  public var body: Data?

  public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }
}

public struct HTTPResponse: Sendable, Equatable {
  public var status: Int
  public var body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

public protocol HTTPTransport: Sendable {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
  private let session: URLSession
  private let timeout: TimeInterval

  public init(session: URLSession = .shared, timeout: TimeInterval = 30) {
    self.session = session
    self.timeout = timeout
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.allHTTPHeaderFields = request.headers
    urlRequest.httpBody = request.body
    urlRequest.timeoutInterval = timeout
    let (body, response) = try await session.data(for: urlRequest)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw YuccaError.http(status: -1, body: "")
    }
    return HTTPResponse(status: httpResponse.statusCode, body: body)
  }
}

public enum YuccaError: Error, Equatable, Sendable {
  case invalidDiscovery(String)
  case unauthorized
  case http(status: Int, body: String)
  case decoding(String)
}

func checkedHTTPResponse(_ response: HTTPResponse) throws -> HTTPResponse {
  if response.status == 401 {
    throw YuccaError.unauthorized
  }
  guard (200..<300).contains(response.status) else {
    let text = String(decoding: response.body, as: UTF8.self)
    throw YuccaError.http(status: response.status, body: String(text.prefix(500)))
  }
  return response
}

func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
  do {
    return try JSONDecoder().decode(type, from: data)
  } catch {
    throw YuccaError.decoding(String(describing: error))
  }
}

func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
  do {
    return try JSONEncoder().encode(value)
  } catch {
    throw YuccaError.decoding(String(describing: error))
  }
}
