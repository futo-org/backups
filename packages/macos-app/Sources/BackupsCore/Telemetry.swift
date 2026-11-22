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

  private static let credentialURL = try! NSRegularExpression(pattern: #"://[^/\s@]+@"#)
  private static let fileURL = try! NSRegularExpression(pattern: #"file://[^\s"',)\]:}]*"#)
  private static let foundationPathKeys = try! NSRegularExpression(
    pattern: #"(NSFilePathErrorKey|NSFilePath|NSURL)=[^,}\s]*"#)
  private static let absolutePath = try! NSRegularExpression(
    pattern: #"(?:^|(?<=[\s(\["'=:-]))~?/(?!/)(?:(?!: )[^"',)\]}\n])+"#)

  public var summary: String
  public var data: [String: TelemetryValue]

  public init(summary: String, data: [String: TelemetryValue] = [:], version: String) {
    self.summary = summary
    var merged = data.mapValues(Self.redacted)
    merged["version"] = .string(version)
    merged["client"] = .string(Self.client)
    self.data = merged
  }

  public static func redact(_ text: String) -> String {
    var result = replace(credentialURL, with: "://***@", in: text)
    result = replace(fileURL, with: "<path>", in: result)
    result = replace(foundationPathKeys, with: "$1=<path>", in: result)
    result = replace(absolutePath, with: "<path>", in: result)
    return result
  }

  private static func replace(
    _ expression: NSRegularExpression, with template: String, in text: String
  ) -> String {
    expression.stringByReplacingMatches(
      in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
  }

  private static func redacted(_ value: TelemetryValue) -> TelemetryValue {
    switch value {
    case .string(let text):
      .string(redact(text))
    case .array(let items):
      .array(items.map(redacted))
    case .object(let entries):
      .object(entries.mapValues(redacted))
    default:
      value
    }
  }
}
