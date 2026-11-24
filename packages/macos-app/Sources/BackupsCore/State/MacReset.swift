import Foundation

public struct LocalFiles: Equatable, Sendable {
  public var configFile: URL
  public var cacheDirectory: URL
  public var snapshotDirectory: URL

  public init(configFile: URL, cacheDirectory: URL, snapshotDirectory: URL) {
    self.configFile = configFile
    self.cacheDirectory = cacheDirectory
    self.snapshotDirectory = snapshotDirectory
  }

  public static func standard(home: URL) -> LocalFiles {
    let applicationSupport = home.appendingPathComponent("Library/Application Support/FUTO Backups")
    return LocalFiles(
      configFile: applicationSupport.appendingPathComponent("config.json"),
      cacheDirectory: home.appendingPathComponent("Library/Caches/FUTO Backups"),
      snapshotDirectory: applicationSupport.appendingPathComponent("Snapshot"))
  }
}

public enum LocalResetItem: Equatable, Hashable, Sendable {
  case secret(SecretKey)
  case config
  case cache
  case diskSnapshots

  public var title: String {
    switch self {
    case .secret: "Keychain items"
    case .config: "settings"
    case .cache: "cache"
    case .diskSnapshots: "disk snapshot files"
    }
  }
}

public struct MacReset: Sendable {
  private let files: LocalFiles
  private let secrets: any SecretStore
  private let cleanUpDiskSnapshots: @Sendable () async -> Void
  private let signOutTimeout: Duration

  public init(
    files: LocalFiles,
    secrets: any SecretStore,
    cleanUpDiskSnapshots: @escaping @Sendable () async -> Void,
    signOutTimeout: Duration = .seconds(10)
  ) {
    self.files = files
    self.secrets = secrets
    self.cleanUpDiskSnapshots = cleanUpDiskSnapshots
    self.signOutTimeout = signOutTimeout
  }

  public func run(signingOut api: (any AccountAPI)? = nil, log: StructuredLog? = nil) async -> [LocalResetItem] {
    await cleanUpDiskSnapshots()
    if let api {
      await bestEffort(within: signOutTimeout) {
        if let log {
          try? await api.submitStructuredLog(log)
        }
        try? await api.logout()
      }
    }
    return wipe()
  }

  private func wipe() -> [LocalResetItem] {
    var failed: [LocalResetItem] = []
    for key in SecretKey.allCases {
      do {
        try secrets.delete(key)
      } catch {
        failed.append(.secret(key))
      }
    }
    if !removeConfigFiles() {
      failed.append(.config)
    }
    if !remove(files.cacheDirectory) {
      failed.append(.cache)
    }
    if !removeContents(of: files.snapshotDirectory) {
      failed.append(.diskSnapshots)
    }
    return failed
  }

  private func removeConfigFiles() -> Bool {
    let directory = files.configFile.deletingLastPathComponent()
    let corruptPrefix = files.configFile.lastPathComponent + ".corrupt-"
    let corrupt = children(of: directory).filter { $0.lastPathComponent.hasPrefix(corruptPrefix) }
    return ([files.configFile] + corrupt).map(remove).allSatisfy { $0 }
  }

  private func removeContents(of directory: URL) -> Bool {
    children(of: directory).map { child in
      guard (try? child.resourceValues(forKeys: [.isVolumeKey]).isVolume) != true else { return false }
      return remove(child)
    }
    .allSatisfy { $0 }
  }

  private func children(of directory: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
  }

  private func remove(_ url: URL) -> Bool {
    do {
      try FileManager.default.removeItem(at: url)
      return true
    } catch {
      return !FileManager.default.fileExists(atPath: url.path)
    }
  }
}
