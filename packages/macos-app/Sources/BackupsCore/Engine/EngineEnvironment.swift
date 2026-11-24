import Foundation

public struct EngineEnvironment: Sendable {
  public var secrets: any SecretStore
  public var discover: @Sendable (URL) async throws -> ServerInfo
  public var makeAPI: @Sendable (URL, String) -> any YuccaRepositoryAPI
  public var restic: any ResticExecuting
  public var proxyLauncher: any ResticProxyLaunching
  public var cacheDirectory: URL
  public var home: String
  public var processorCount: Int
  public var now: @Sendable () -> Date
  public var elapsedNow: @Sendable () -> ContinuousClock.Instant
  public var appVersion: String
  public var telemetryTimeout: Duration
  public var diskSnapshots: any DiskSnapshotting
  public var snapshotDirectory: URL?
  public var dataVolumePath: @Sendable (String) -> String?
  public var createRestoreDirectory: @Sendable (URL) throws -> Bool
  public var temporaryDirectory: URL

  public init(
    secrets: any SecretStore,
    discover: @escaping @Sendable (URL) async throws -> ServerInfo,
    makeAPI: @escaping @Sendable (URL, String) -> any YuccaRepositoryAPI,
    restic: any ResticExecuting,
    proxyLauncher: any ResticProxyLaunching,
    cacheDirectory: URL,
    home: String,
    processorCount: Int,
    now: @escaping @Sendable () -> Date,
    elapsedNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    appVersion: String = "dev",
    telemetryTimeout: Duration = .seconds(10),
    diskSnapshots: any DiskSnapshotting = UnavailableDiskSnapshots(),
    snapshotDirectory: URL? = nil,
    dataVolumePath: @escaping @Sendable (String) -> String? = { _ in nil },
    createRestoreDirectory: @escaping @Sendable (URL) throws -> Bool = RestorePlan.createDirectoryExclusively,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    self.secrets = secrets
    self.discover = discover
    self.makeAPI = makeAPI
    self.restic = restic
    self.proxyLauncher = proxyLauncher
    self.cacheDirectory = cacheDirectory
    self.home = home
    self.processorCount = processorCount
    self.now = now
    self.elapsedNow = elapsedNow
    self.appVersion = appVersion
    self.telemetryTimeout = telemetryTimeout
    self.diskSnapshots = diskSnapshots
    self.snapshotDirectory = snapshotDirectory
    self.dataVolumePath = dataVolumePath
    self.createRestoreDirectory = createRestoreDirectory
    self.temporaryDirectory = temporaryDirectory
  }
}

public enum EngineError: Error, Equatable, Sendable {
  case notLoggedIn
  case noRepository
  case noFolders
  case missingMasterKey
  case busy
  case restic(code: Int32, message: String)
}

public enum EngineActivity: Equatable, Sendable {
  case preparing
  case backingUp(BackupProgress)
  case pruning
  case restoring
  case changingRecoveryKey
}
