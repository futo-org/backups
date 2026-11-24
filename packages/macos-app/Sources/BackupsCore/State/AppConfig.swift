import Foundation

public struct RunRecord: Codable, Equatable, Sendable {
  public var startedAt: Date
  public var finishedAt: Date
  public var status: BackupStatus
  public var snapshotId: String?
  public var filesNew: Int?
  public var dataAdded: Int64?
  public var message: String?
  public var cloudOnlySkipped: CloudOnlySkip?
  public var warnings: BackupWarnings?

  public init(
    startedAt: Date, finishedAt: Date, status: BackupStatus, snapshotId: String? = nil,
    filesNew: Int? = nil, dataAdded: Int64? = nil, message: String? = nil, cloudOnlySkipped: CloudOnlySkip? = nil,
    warnings: BackupWarnings? = nil
  ) {
    self.startedAt = startedAt
    self.finishedAt = finishedAt
    self.status = status
    self.snapshotId = snapshotId
    self.filesNew = filesNew
    self.dataAdded = dataAdded
    self.message = message
    self.cloudOnlySkipped = cloudOnlySkipped
    self.warnings = warnings
  }
}

public struct RememberedRepository: Codable, Equatable, Sendable {
  public var id: String
  public var lastRun: RunRecord?
  public var scheduleAnchor: Date?

  public init(id: String, lastRun: RunRecord? = nil, scheduleAnchor: Date? = nil) {
    self.id = id
    self.lastRun = lastRun
    self.scheduleAnchor = scheduleAnchor
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
  public var onboardingCompletedAt: Date?
  public var excludeDefaultsVersion: Int?
  public var repositoriesByServer: [String: RememberedRepository]?
  public var uploadConnections: Int?
  public var readConcurrency: Int?
  public var retention: SnapshotRetention?

  public static let parallelismChoices = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 128]

  public var usesDiskSnapshots: Bool { diskSnapshots ?? true }

  public var snapshotRetention: SnapshotRetention { retention ?? .standard }

  public var scheduleReference: Date? { lastRun?.startedAt ?? scheduleAnchor }

  public var serverDisplayName: String {
    if serverURL == Self.productionServerURL {
      return "futo.cloud"
    }
    guard let host = serverURL.host() else { return serverURL.absoluteString }
    return serverURL.port.map { "\(host):\($0)" } ?? host
  }

  public static let devServerURL: URL = URL(string: "http://localhost:8081/.well-known/yucca.json")!
  public static let productionServerURL: URL = URL(string: "https://meta.futo.cloud/.well-known/yucca.json")!

  public static let defaultExcludesByVersion: [[String]] = [
    [
      "~/Library/Caches",
      "~/Library/Mobile Documents",
      "~/Library/CloudStorage",
      "~/Library/Containers/*/Data/Library/Caches",
      "~/.Trash",
      "**/node_modules",
      "**/.DS_Store",
    ],
    [
      "~/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data",
      "~/Library/Containers/com.docker.docker/Data/vms",
      "~/Library/Application Support/rancher-desktop/lima",
      "~/Library/Application Support/Claude/vm_bundles",
      "~/.colima/_lima",
      "~/.lima/*/basedisk",
      "~/.lima/*/diffdisk",
      "~/.local/share/containers/podman/machine",
    ],
    [
      "~/Library/Application Support/FileProvider",
      "~/Library/Application Support/com.apple.TCC",
      "~/Library/Group Containers/group.com.apple.secure-control-center-preferences",
      "~/Library/Biome",
      "~/Library/Metadata/CoreSpotlight",
      "~/Library/Daemon Containers",
      "~/Library/Trial",
      "~/Library/DuetExpertCenter",
    ],
  ]

  public static let defaultExcludes: [String] = defaultExcludesByVersion.flatMap { $0 }

  public static var currentExcludeDefaultsVersion: Int { defaultExcludesByVersion.count }

  public static func defaults(host: String, home: String) -> AppConfig {
    var config = AppConfig(
      serverURL: productionServerURL,
      folders: [],
      excludes: defaultExcludes.map { expandingHome($0, home: home) },
      schedule: .daily(hour: 12, minute: 0),
      throttle: .unthrottled,
      host: host,
      repositoryId: nil,
      lastRun: nil,
      scheduleAnchor: nil
    )
    config.excludeDefaultsVersion = currentExcludeDefaultsVersion
    return config
  }

  public mutating func switchServer(to url: URL) {
    guard url != serverURL else { return }
    var remembered = repositoriesByServer ?? [:]
    remembered[serverURL.absoluteString] = repositoryId.map {
      RememberedRepository(id: $0, lastRun: lastRun, scheduleAnchor: scheduleAnchor)
    }
    let restored = remembered[url.absoluteString]
    serverURL = url
    repositoryId = restored?.id
    lastRun = restored?.lastRun
    scheduleAnchor = restored?.scheduleAnchor
    repositoriesByServer = remembered.isEmpty ? nil : remembered
  }

  public mutating func pinToProductionServer() -> Bool {
    guard serverURL != Self.productionServerURL else { return false }
    switchServer(to: Self.productionServerURL)
    return true
  }

  public mutating func addNewDefaultExcludes(home: String) -> Bool {
    let seen = excludeDefaultsVersion ?? 1
    guard seen < Self.currentExcludeDefaultsVersion else { return false }
    for pattern in Self.defaultExcludesByVersion.dropFirst(seen).flatMap({ $0 }) {
      let expanded = Self.expandingHome(pattern, home: home)
      let coversChosenFolder = ExcludePattern(expanded).map { folders.contains(where: $0.matches) } ?? false
      if !excludes.contains(expanded), !coversChosenFolder {
        excludes.append(expanded)
      }
    }
    excludeDefaultsVersion = Self.currentExcludeDefaultsVersion
    return true
  }

  private static func expandingHome(_ pattern: String, home: String) -> String {
    pattern.hasPrefix("~/") ? home + pattern.dropFirst() : pattern
  }

  public mutating func forgetRepository(unlessListedIn repositories: [RemoteRepository]) -> Bool {
    guard let repositoryId, !repositories.contains(where: { $0.id == repositoryId }) else { return false }
    self.repositoryId = nil
    recoveryKeyConfirmedAt = nil
    lastRun = nil
    return true
  }
}
