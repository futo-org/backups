import Foundation

public actor BackupEngine {
  public static let keepWithin = "60d"

  private struct Session {
    var proxy: any ResticProxyHandle
    var context: ResticContext
  }

  private final class Outbox: @unchecked Sendable {
    private let continuation: AsyncStream<@Sendable () async -> Void>.Continuation
    private let consumer: Task<Void, Never>

    init(timeout: Duration) {
      let (stream, continuation) = AsyncStream<@Sendable () async -> Void>.makeStream()
      self.continuation = continuation
      self.consumer = Task {
        for await job in stream {
          await withTaskGroup(of: Void.self) { group in
            group.addTask { await job() }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
          }
        }
      }
    }

    func enqueue(_ job: @escaping @Sendable () async -> Void) {
      continuation.yield(job)
    }

    func flush() async {
      await withCheckedContinuation { (wait: CheckedContinuation<Void, Never>) in
        continuation.yield { wait.resume() }
      }
    }

    deinit {
      continuation.finish()
    }
  }

  private let environment: EngineEnvironment
  private let outbox: Outbox
  private var running = false
  private var serverCache: [URL: ServerInfo] = [:]
  private var futoResticCache: Bool?

  public init(environment: EngineEnvironment) {
    self.environment = environment
    self.outbox = Outbox(timeout: environment.telemetryTimeout)
  }

  public func flushOutbox() async {
    await outbox.flush()
  }

  public func masterKey() throws -> String {
    if let stored = try environment.secrets.get(.masterKey) {
      return stored
    }
    let generated = RepositoryKeys.generateMasterKey()
    try environment.secrets.set(generated, for: .masterKey)
    return generated
  }

  public func storedMasterKey() throws -> String? {
    try environment.secrets.get(.masterKey)
  }

  public func importMasterKey(_ input: String) throws {
    guard let key = RepositoryKeys.normalizedMasterKey(input) else {
      throw RepositoryKeysError.invalidMasterKey
    }
    try environment.secrets.set(key, for: .masterKey)
  }

  public func ensureRepository(config: AppConfig) async throws -> String {
    if running {
      throw EngineError.busy
    }
    running = true
    defer { running = false }
    if let repositoryId = config.repositoryId {
      return repositoryId
    }
    let token = try accessToken()
    let server = try await serverInfo(for: config.serverURL)
    let api = environment.makeAPI(server.apiRoot, token)
    let masterKey = try requireMasterKey()
    let created = try await api.createRepository(name: config.host)
    let session = try await startSession(
      config: config, repositoryId: created.id, masterKey: masterKey, token: token)
    let result: ResticResult
    do {
      result = try await environment.restic.run(ResticCommand.initialize(session.context), onLine: { _ in })
    } catch {
      await session.proxy.stop()
      throw error
    }
    await session.proxy.stop()
    guard result.exitCode == ResticExitCode.success else {
      throw EngineError.restic(
        code: result.exitCode,
        message: ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode))
    }
    await report(
      api, config: config, "Created repository", ["repositoryId": .string(created.id)])
    return created.id
  }

  public func backup(config: AppConfig, onActivity: @escaping @Sendable (EngineActivity) -> Void) async throws
    -> RunRecord
  {
    if running {
      throw EngineError.busy
    }
    guard let repositoryId = config.repositoryId else {
      throw EngineError.noRepository
    }
    guard !config.folders.isEmpty else {
      throw EngineError.noFolders
    }
    let token = try accessToken()
    let masterKey = try requireMasterKey()
    running = true
    defer { running = false }
    let startedAt = environment.now()
    onActivity(.preparing)
    var status: BackupStatus = .failed
    var message: String?
    var summary: BackupSummary?
    var snapshotMounted = false
    var api: (any YuccaRepositoryAPI)?
    do {
      let server = try await serverInfo(for: config.serverURL)
      let madeAPI = environment.makeAPI(server.apiRoot, token)
      api = madeAPI
      await report(
        madeAPI, config: config, "Running backup", ["repositoryId": .string(repositoryId)])
      outbox.enqueue {
        try? await madeAPI.submitBackupStart(repositoryId: repositoryId)
      }
      let session = try await startSession(
        config: config, repositoryId: repositoryId, masterKey: masterKey, token: token)
      do {
        _ = try await environment.restic.run(ResticCommand.unlock(session.context), onLine: { _ in })
        try Task.checkCancellation()
        let relatives = config.folders.map { environment.dataVolumePath($0) }
        let snapshotMode = config.usesDiskSnapshots && relatives.contains { $0 != nil }
        var createdSnapshot: DiskSnapshot?
        var snapshotMountPoint: URL?
        var snapshotMarker: URL?
        var mounted = false
        var snapshotCleanedUp = false
        var backupPaths = config.folders
        var backupExcludes = config.excludes
        var backupCurrentDirectory: String?
        func runSnapshotCleanup() async {
          guard !snapshotCleanedUp, let createdSnapshot, let snapshotMountPoint else { return }
          snapshotCleanedUp = true
          let cleanupError = await Task {
            await self.cleanUpSnapshot(
              createdSnapshot, mountPoint: snapshotMountPoint, mounted: mounted, marker: snapshotMarker)
          }.value
          if let cleanupError {
            await report(
              madeAPI, config: config, "Failed to remove disk snapshot",
              ["repositoryId": .string(repositoryId), "error": .string(cleanupError)])
          }
        }
        if snapshotMode {
          do {
            guard let snapshotDirectory = environment.snapshotDirectory else {
              throw DiskSnapshotError.unavailable
            }
            guard environment.hasFullDiskAccess() else {
              throw DiskSnapshotError.noFullDiskAccess
            }
            let mountPoint = snapshotDirectory.appendingPathComponent("Volume")
            let marker = snapshotDirectory.appendingPathComponent("pending.json")
            snapshotMountPoint = mountPoint
            snapshotMarker = marker
            if environment.diskSnapshots.isMounted(mountPoint) {
              try? await environment.diskSnapshots.unmount(mountPoint)
            }
            if let stale = try? JSONDecoder().decode(DiskSnapshot.self, from: Data(contentsOf: marker)) {
              try? await environment.diskSnapshots.delete(stale)
            }
            try? FileManager.default.removeItem(at: marker)
            let snapshot = try await environment.diskSnapshots.create()
            createdSnapshot = snapshot
            try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: marker, options: .atomic)
            try await environment.diskSnapshots.mount(snapshot, at: mountPoint)
            mounted = true
            snapshotMounted = true
            var snapshotPaths: [String] = []
            for index in config.folders.indices {
              snapshotPaths.append(relatives[index] ?? config.folders[index])
            }
            backupPaths = snapshotPaths
            let resolvedMount = DataVolume.resolvedPath(mountPoint.path)
            for exclude in config.excludes {
              if let relative = DataVolume.snapshotRelativePath(exclude) {
                backupExcludes.append(relative == "." ? resolvedMount : resolvedMount + "/" + relative)
              }
            }
            backupCurrentDirectory = resolvedMount
          } catch {
            await runSnapshotCleanup()
            if !(error is CancellationError) {
              await report(
                madeAPI, config: config, "Failed to create disk snapshot",
                [
                  "repositoryId": .string(repositoryId),
                  "error": .string(String(describing: error)),
                ])
            }
            throw error
          }
        }
        let log = ResticLineLog()
        let result: ResticResult
        do {
          result = try await environment.restic.run(
            ResticCommand.backup(
              session.context, paths: backupPaths, excludes: backupExcludes, host: config.host,
              currentDirectory: backupCurrentDirectory),
            onLine: { line in
              log.append(line)
              if case .status(let progress) = ResticOutput.parseLine(line) {
                onActivity(.backingUp(progress))
              }
            })
        } catch {
          await runSnapshotCleanup()
          throw error
        }
        await runSnapshotCleanup()
        var lastError: String?
        for line in log.lines {
          switch ResticOutput.parseLine(line) {
          case .summary(let value): summary = value
          case .error(let text): lastError = text
          default: break
          }
        }
        if result.exitCode == ResticExitCode.success {
          status = .complete
        } else if result.exitCode == ResticExitCode.couldNotReadSource {
          status = .warn
          message = lastError ?? ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode)
        } else {
          status = .failed
          message = ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode)
        }
        if status == .complete {
          onActivity(.pruning)
          await report(
            madeAPI, config: config, "Running repository prune",
            [
              "repositoryId": .string(repositoryId),
              "retentionPolicy": .string("keep-within \(Self.keepWithin)"),
            ])
          var pruneError: String?
          do {
            let forget = try await environment.restic.run(
              ResticCommand.forget(session.context, host: config.host, keepWithin: Self.keepWithin),
              onLine: { _ in })
            if forget.exitCode != ResticExitCode.success {
              let detail = ResticOutput.errorMessage(
                stderr: forget.stderr, exitCode: forget.exitCode)
              pruneError = detail
              message = "Prune failed: " + detail
            }
          } catch {
            if error is CancellationError {
              throw error
            }
            let detail = String(describing: error)
            pruneError = detail
            message = "Prune failed: \(detail)"
          }
          if let pruneError {
            await report(
              madeAPI, config: config, "Finished repository prune",
              ["repositoryId": .string(repositoryId), "error": .string(pruneError)])
          } else {
            await report(
              madeAPI, config: config, "Finished repository prune",
              ["repositoryId": .string(repositoryId)])
          }
        }
        if status == .complete || status == .warn {
          var totalSize: Int64?
          var statsError: String?
          do {
            let stats = try await environment.restic.run(
              ResticCommand.stats(session.context), onLine: { _ in })
            if stats.exitCode == ResticExitCode.success {
              do {
                totalSize = try ResticOutput.parseStatsTotalSize(stats.stdout)
              } catch {
                statsError = String(describing: error)
              }
            } else {
              statsError = ResticOutput.errorMessage(
                stderr: stats.stderr, exitCode: stats.exitCode)
            }
          } catch {
            if !(error is CancellationError) {
              statsError = String(describing: error)
            }
          }
          if let statsError {
            await report(
              madeAPI, config: config, "Failed to read repository stats",
              ["repositoryId": .string(repositoryId), "error": .string(statsError)])
          }
          if let totalSize {
            outbox.enqueue {
              try? await madeAPI.submitRepositorySize(
                repositoryId: repositoryId, sizeBytes: totalSize)
            }
          }
        }
      } catch {
        await session.proxy.stop()
        throw error
      }
      await session.proxy.stop()
    } catch {
      if error is CancellationError {
        status = .cancelled
      } else {
        status = .failed
        message = String(describing: error)
      }
    }
    let finishedAt = environment.now()
    let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)
    let endStatus = status
    let endMessage = (status == .failed || status == .warn) ? message : nil
    if let endAPI = api {
      outbox.enqueue {
        try? await endAPI.submitBackupEnd(
          repositoryId: repositoryId, status: endStatus, durationMs: durationMs)
      }
      var data: [String: TelemetryValue] = [
        "repositoryId": .string(repositoryId),
        "lastBackupStatus": .string(endStatus.rawValue),
        "durationMs": .int(Int64(durationMs)),
        "diskSnapshot": .bool(snapshotMounted),
      ]
      if let endMessage {
        data["error"] = .string(endMessage)
      }
      await report(endAPI, config: config, "Backup finished", data)
    }
    return RunRecord(
      startedAt: startedAt, finishedAt: finishedAt, status: status, snapshotId: summary?.snapshotId,
      filesNew: summary?.filesNew, dataAdded: summary?.dataAdded, message: message)
  }

  private func cleanUpSnapshot(
    _ snapshot: DiskSnapshot, mountPoint: URL, mounted: Bool, marker: URL?
  ) async -> String? {
    var firstError: String?
    if mounted {
      do {
        try await environment.diskSnapshots.unmount(mountPoint)
      } catch {
        firstError = String(describing: error)
      }
    }
    var deleteSucceeded = false
    do {
      try await environment.diskSnapshots.delete(snapshot)
      deleteSucceeded = true
    } catch {
      if firstError == nil {
        firstError = String(describing: error)
      }
    }
    if deleteSucceeded, let marker {
      try? FileManager.default.removeItem(at: marker)
    }
    return firstError
  }

  private func mapSnapshotPaths(_ snapshots: [Snapshot]) -> [Snapshot] {
    guard let snapshotDirectory = environment.snapshotDirectory else {
      return snapshots
    }
    let mount = snapshotDirectory.appendingPathComponent("Volume").path
    let mounts = [mount, DataVolume.resolvedPath(mount)]
    return snapshots.map { snapshot in
      var copy = snapshot
      copy.paths = snapshot.paths.map { path in
        for mount in mounts {
          if path == mount {
            return "/"
          }
          if path.hasPrefix(mount + "/") {
            return "/" + path.dropFirst(mount.count + 1)
          }
        }
        return path
      }
      return copy
    }
  }

  public func snapshots(config: AppConfig) async throws -> [Snapshot] {
    guard let repositoryId = config.repositoryId else {
      throw EngineError.noRepository
    }
    let token = try accessToken()
    let session = try await startSession(
      config: config, repositoryId: repositoryId, masterKey: try requireMasterKey(), token: token)
    let server = try await serverInfo(for: config.serverURL)
    let api = environment.makeAPI(server.apiRoot, token)
    let result: ResticResult
    do {
      result = try await environment.restic.run(ResticCommand.snapshots(session.context), onLine: { _ in })
    } catch {
      await session.proxy.stop()
      if !(error is CancellationError) {
        await report(
          api, config: config, "Failed to get repository snapshot listing",
          ["repositoryId": .string(repositoryId), "error": .string(String(describing: error))])
      }
      throw error
    }
    await session.proxy.stop()
    guard result.exitCode == ResticExitCode.success else {
      let detail = ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode)
      await report(
        api, config: config, "Failed to get repository snapshot listing",
        ["repositoryId": .string(repositoryId), "error": .string(detail)])
      throw EngineError.restic(code: result.exitCode, message: detail)
    }
    do {
      return mapSnapshotPaths(try ResticOutput.parseSnapshots(result.stdout)).sorted { $0.time > $1.time }
    } catch {
      await report(
        api, config: config, "Failed to get repository snapshot listing",
        ["repositoryId": .string(repositoryId), "error": .string(String(describing: error))])
      throw error
    }
  }

  public func restore(
    config: AppConfig, snapshotId: String, target: URL, include: [String],
    onActivity: @escaping @Sendable (EngineActivity) -> Void
  ) async throws {
    if running {
      throw EngineError.busy
    }
    guard let repositoryId = config.repositoryId else {
      throw EngineError.noRepository
    }
    let token = try accessToken()
    let masterKey = try requireMasterKey()
    running = true
    defer { running = false }
    let session = try await startSession(
      config: config, repositoryId: repositoryId, masterKey: masterKey, token: token)
    let server = try await serverInfo(for: config.serverURL)
    let api = environment.makeAPI(server.apiRoot, token)
    onActivity(.restoring)
    var restoreData: [String: TelemetryValue] = [
      "repositoryId": .string(repositoryId),
      "snapshotId": .string(snapshotId),
    ]
    await report(api, config: config, "Running repository snapshot restore", restoreData)
    let result: ResticResult
    do {
      result = try await environment.restic.run(
        ResticCommand.restore(session.context, snapshotId: snapshotId, target: target.path, include: include),
        onLine: { _ in })
    } catch {
      await session.proxy.stop()
      restoreData["error"] = .string(error is CancellationError ? "cancelled" : String(describing: error))
      await report(api, config: config, "Finished repository snapshot restore", restoreData)
      throw error
    }
    await session.proxy.stop()
    guard result.exitCode == ResticExitCode.success else {
      let detail = ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode)
      restoreData["error"] = .string(detail)
      await report(api, config: config, "Finished repository snapshot restore", restoreData)
      throw EngineError.restic(code: result.exitCode, message: detail)
    }
    await report(api, config: config, "Finished repository snapshot restore", restoreData)
  }

  public func macRepositories(config: AppConfig) async throws -> [RemoteRepository] {
    let token = try accessToken()
    let server = try await serverInfo(for: config.serverURL)
    let api = environment.makeAPI(server.apiRoot, token)
    let repositories = try await api.listRepositories()
    return repositories.filter { $0.connectionType == "macos" }.sorted { lhs, rhs in
      switch (lhs.lastBackup, rhs.lastBackup) {
      case let (left?, right?):
        if left != right {
          return left > right
        }
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        break
      }
      return lhs.name < rhs.name
    }
  }

  public func verifyMasterKey(
    _ masterKey: String, config: AppConfig, repositoryId: String
  ) async throws -> Bool {
    if running {
      throw EngineError.busy
    }
    guard let normalized = RepositoryKeys.normalizedMasterKey(masterKey) else {
      throw RepositoryKeysError.invalidMasterKey
    }
    let token = try accessToken()
    running = true
    defer { running = false }
    let session = try await startSession(
      config: config, repositoryId: repositoryId, masterKey: normalized, token: token)
    let result: ResticResult
    do {
      result = try await environment.restic.run(ResticCommand.catConfig(session.context), onLine: { _ in })
    } catch {
      await session.proxy.stop()
      throw error
    }
    await session.proxy.stop()
    switch result.exitCode {
    case ResticExitCode.success:
      return true
    case ResticExitCode.wrongPassword:
      return false
    default:
      throw EngineError.restic(
        code: result.exitCode,
        message: ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode))
    }
  }

  private func accessToken() throws -> String {
    guard let token = try environment.secrets.get(.accessToken) else {
      throw EngineError.notLoggedIn
    }
    return token
  }

  private func requireMasterKey() throws -> String {
    guard let masterKey = try storedMasterKey() else {
      throw EngineError.missingMasterKey
    }
    return masterKey
  }

  private func serverInfo(for url: URL) async throws -> ServerInfo {
    if let cached = serverCache[url] {
      return cached
    }
    let server = try await environment.discover(url)
    serverCache[url] = server
    return server
  }

  private func report(
    _ api: any YuccaRepositoryAPI, config: AppConfig, _ summary: String,
    _ data: [String: TelemetryValue]
  ) async {
    guard config.telemetryConsentedAt != nil else {
      return
    }
    let log = StructuredLog(summary: summary, data: data, version: environment.appVersion)
    outbox.enqueue {
      try? await api.submitStructuredLog(log)
    }
  }

  private func isFutoRestic() async -> Bool {
    if let cached = futoResticCache {
      return cached
    }
    guard
      let result = try? await environment.restic.run(
        ResticCommand.version(home: environment.home), onLine: { _ in }),
      result.exitCode == ResticExitCode.success,
      let version = try? ResticOutput.parseVersion(result.stdout)
    else {
      return false
    }
    let futo = version.contains("+futo.")
    futoResticCache = futo
    return futo
  }

  private func startSession(
    config: AppConfig, repositoryId: String, masterKey: String, token: String
  ) async throws -> Session {
    let server = try await serverInfo(for: config.serverURL)
    let proxy = try await environment.proxyLauncher.start(apiRoot: server.apiRoot, throttle: config.throttle)
    do {
      let context = ResticContext(
        repository: resticProxyRepositoryURL(
          address: proxy.address, repositoryId: repositoryId, accessToken: token),
        password: try RepositoryKeys.password(masterKey: masterKey, repositoryId: repositoryId),
        cacheDirectory: environment.cacheDirectory,
        home: environment.home,
        connections: max(
          1, Int(server.connectionsMath.trimmingCharacters(in: .whitespaces)) ?? environment.processorCount),
        packSizeMiB: server.resticPackSizeMiB,
        walkConcurrency: await isFutoRestic() ? 64 : nil)
      return Session(proxy: proxy, context: context)
    } catch {
      await proxy.stop()
      throw error
    }
  }
}

private final class ResticLineLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  func append(_ line: String) {
    lock.lock()
    stored.append(line)
    lock.unlock()
  }

  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
