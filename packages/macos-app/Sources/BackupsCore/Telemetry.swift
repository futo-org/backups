import Foundation

public enum TelemetryValue: Encodable, Equatable, Sendable {
  case string(String)
  case int(Int64)
  case bool(Bool)
  case date(Date)
  case array([TelemetryValue])
  case object([String: TelemetryValue])

  public static func error(_ error: any Error) -> TelemetryValue {
    .object([
      "type": .string(String(reflecting: type(of: error))),
      "message": .string(String(describing: error)),
    ])
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .date(let value):
      try container.encode(
        value.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }
}

public struct StructuredLog: Encodable, Equatable, Sendable {
  public static let client = "macos"

  public var summary: String
  public var data: [String: TelemetryValue]

  public init(summary: String, data: [String: TelemetryValue] = [:], version: String) {
    self.summary = summary
    var merged = data
    merged["version"] = .string(version)
    merged["client"] = .string(Self.client)
    self.data = merged
  }
}
