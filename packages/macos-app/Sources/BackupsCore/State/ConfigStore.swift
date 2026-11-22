import Foundation

public struct ConfigStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public static func standard() -> ConfigStore {
    let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return ConfigStore(
      fileURL:
        applicationSupport
        .appendingPathComponent("FUTO Backups")
        .appendingPathComponent("config.json"))
  }

  public func load(defaultHost: String, home: String) throws -> AppConfig {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return AppConfig.defaults(host: defaultHost, home: home)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(AppConfig.self, from: Data(contentsOf: fileURL))
  }

  public func save(_ config: AppConfig) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(config)
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
  }
}
