import Foundation

public struct RunRecord: Codable, Equatable, Sendable {
  public var startedAt: Date
  public var finishedAt: Date
  public var status: BackupStatus
  public var snapshotId: String?
  public var filesNew: Int?
  public var dataAdded: Int64?
  public var message: String?

  public init(
    startedAt: Date, finishedAt: Date, status: BackupStatus, snapshotId: String? = nil,
    filesNew: Int? = nil, dataAdded: Int64? = nil, message: String? = nil
  ) {
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.status = status
    self.snapshotId = snapshotId
    self.filesNew = filesNew
    self.dataAdded = dataAdded
    self.message = message
  }
}

public struct AppConfig: Codable, Equatable, Sendable {
  public var serverURL: URL
  public var folders: [String]
  public var excludes: [String]
  public var schedule: Schedule
  public var throttle: Throttle
  public var host: String
  public var repositoryId: String?
  public var lastRun: RunRecord?
  public var scheduleAnchor: Date?
  public var recoveryKeyConfirmedAt: Date?
  public var telemetryConsentedAt: Date?
  public var diskSnapshots: Bool?

  public var usesDiskSnapshots: Bool { diskSnapshots ?? true }

  public var scheduleReference: Date? { lastRun?.startedAt ?? scheduleAnchor }

  public var serverDisplayName: String {
    if serverURL == Self.productionServerURL {
      return "futo.cloud"
    }
    guard let host = serverURL.host() else { return serverURL.absoluteString }
    return serverURL.port.map { "\(host):\($0)" } ?? host
  }

  public static let devServerURL: URL = URL(string: "http://localhost:8080/.well-known/yucca.json")!
  public static let productionServerURL: URL = URL(string: "https://meta.futo.cloud/.well-known/yucca.json")!

  public static let defaultExcludes: [String] = [
    "~/Library/Caches",
    "~/Library/Mobile Documents",
    "~/Library/CloudStorage",
    "~/Library/Containers/*/Data/Library/Caches",
    "~/.Trash",
    "**/node_modules",
    "**/.DS_Store",
  ]

  public static func defaults(host: String, home: String) -> AppConfig {
    AppConfig(
      serverURL: productionServerURL,
      folders: [],
      excludes: defaultExcludes.map { $0.hasPrefix("~/") ? home + $0.dropFirst() : $0 },
      schedule: .daily(hour: 12, minute: 0),
      throttle: .unthrottled,
      host: host,
      repositoryId: nil,
      lastRun: nil,
      scheduleAnchor: nil
    )
  }
}
