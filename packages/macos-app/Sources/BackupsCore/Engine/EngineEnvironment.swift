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
  public var appVersion: String
  public var telemetryTimeout: Duration

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
    appVersion: String = "dev",
    telemetryTimeout: Duration = .seconds(10)
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
    self.appVersion = appVersion
    self.telemetryTimeout = telemetryTimeout
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
}
