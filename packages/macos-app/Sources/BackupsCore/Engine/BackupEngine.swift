import Foundation

public actor BackupEngine {
  public static let keepWithin = "60d"

  private struct Session {
    var proxy: any ResticProxyHandle
    var context: ResticContext
  }

  private struct SnapshotRemoval {
    var error: DiskSnapshotError?
    var deleted: Bool
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
  private var staleCleanupTask: Task<Void, Never>?
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
    var snapshotFailure: DiskSnapshotError?
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
        var snapshotJournal: URL?
        var snapshotLock: SnapshotLock?
        var mounted = false
        var snapshotCleanedUp = false
        var backupPaths = config.folders
        var backupExcludes = config.excludes
        var backupCurrentDirectory: String?
        var backupTags: [String] = []
        func runSnapshotCleanup() async {
          guard !snapshotCleanedUp, let createdSnapshot, let snapshotMountPoint, let snapshotJournal
          else { return }
          snapshotCleanedUp = true
          let removal = await Task {
            await self.removeSnapshot(createdSnapshot, mountPoint: snapshotMountPoint)
          }.value
          if removal.deleted {
            try? writeJournal(
              readJournal(snapshotJournal).filter { $0 != createdSnapshot }, to: snapshotJournal)
          }
          if let error = removal.error {
            await report(
              madeAPI, config: config, "Failed to remove disk snapshot",
              ["repositoryId": .string(repositoryId), "error": .string(error.telemetryCode)])
          }
          snapshotLock?.release()
          snapshotLock = nil
        }
        if snapshotMode {
          do {
            guard let snapshotDirectory = environment.snapshotDirectory else {
              throw DiskSnapshotError.unavailable
            }
            await staleCleanupTask?.value
            let mountPoint = snapshotDirectory.appendingPathComponent("Volume")
            let journal = snapshotDirectory.appendingPathComponent("pending.json")
            let lockFile = snapshotDirectory.appendingPathComponent("lock")
            snapshotMountPoint = mountPoint
            snapshotJournal = journal
            try? FileManager.default.createDirectory(
              at: snapshotDirectory,
              withIntermediateDirectories: true,
              attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes(
              [.posixPermissions: 0o700], ofItemAtPath: snapshotDirectory.path)
            guard let lock = SnapshotLock.acquire(at: lockFile) else {
              throw DiskSnapshotError.createFailed("another backup is using disk snapshots")
            }
            snapshotLock = lock
            let staleErrors = await Task {
              await self.cleanUpStaleSnapshots(directory: snapshotDirectory)
            }.value
            for error in staleErrors {
              await report(
                madeAPI, config: config, "Failed to remove disk snapshot",
                ["repositoryId": .string(repositoryId), "error": .string(error.telemetryCode)])
            }
            let snapshot = try await Task {
              try await self.environment.diskSnapshots.create()
            }.value
            createdSnapshot = snapshot
            do {
              try writeJournal(readJournal(journal) + [snapshot], to: journal)
            } catch {
              throw DiskSnapshotError.createFailed("could not record the snapshot")
            }
            do {
              try await Task {
                try await self.environment.diskSnapshots.mount(snapshot, at: mountPoint)
              }.value
            } catch {
              mounted = environment.diskSnapshots.mountedSnapshotName(at: mountPoint) == snapshot.name
              throw error
            }
            mounted = environment.diskSnapshots.mountedSnapshotName(at: mountPoint) == snapshot.name
            if !mounted {
              throw DiskSnapshotError.mountFailed("the snapshot is not mounted")
            }
            snapshotMounted = true
            backupTags = ["disk-snapshot"]
            try Task.checkCancellation()
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
            snapshotLock?.release()
            snapshotLock = nil
            snapshotFailure = error as? DiskSnapshotError
            if !(error is CancellationError) {
              await report(
                madeAPI, config: config, "Failed to create disk snapshot",
                [
                  "repositoryId": .string(repositoryId),
                  "error": .string(
                    (error as? DiskSnapshotError)?.telemetryCode
                      ?? String(describing: type(of: error))),
                ])
            }
            throw error
          }
        }
        let output = BackupOutput()
        let result: ResticResult
        do {
          result = try await environment.restic.run(
            ResticCommand.backup(
              session.context, paths: backupPaths, excludes: backupExcludes, host: config.host,
              currentDirectory: backupCurrentDirectory, tags: backupTags),
            onLine: { line in
              let message = ResticOutput.parseLine(line)
              if case .status(let progress) = message {
                onActivity(.backingUp(progress))
              } else {
                output.record(message)
              }
            })
        } catch {
          await runSnapshotCleanup()
          snapshotLock?.release()
          snapshotLock = nil
          throw error
        }
        await runSnapshotCleanup()
        snapshotLock?.release()
        snapshotLock = nil
        summary = output.summary
        let lastError = output.lastError
        if result.exitCode == ResticExitCode.success {
          status = .complete
        } else if result.exitCode == ResticExitCode.couldNotReadSource {
          status = .warn
          message =
            ResticOutput.lastItemError(stderr: result.stderr) ?? lastError
            ?? ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode)
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
      if let snapshotFailure {
        data["error"] = .string("disk snapshot: \(snapshotFailure.telemetryCode)")
      } else if let endMessage {
        data["error"] = .string(endMessage)
      }
      await report(endAPI, config: config, "Backup finished", data)
    }
    return RunRecord(
      startedAt: startedAt, finishedAt: finishedAt, status: status, snapshotId: summary?.snapshotId,
      filesNew: summary?.filesNew, dataAdded: summary?.dataAdded, message: message)
  }

  private func readJournal(_ url: URL) -> [DiskSnapshot] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([DiskSnapshot].self, from: data)) ?? []
  }

  private func writeJournal(_ entries: [DiskSnapshot], to url: URL) throws {
    if entries.isEmpty {
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        let nsError = error as NSError
        let cocoaNotFound =
          nsError.domain == NSCocoaErrorDomain
          && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)
        let posixNotFound = (error as? POSIXError).map { $0.code.rawValue == Int32(ENOENT) } ?? false
        if !cocoaNotFound && !posixNotFound {
          throw error
        }
      }
      return
    }
    try JSONEncoder().encode(entries).write(to: url, options: .atomic)
  }

  private func removeSnapshot(_ snapshot: DiskSnapshot, mountPoint: URL) async -> SnapshotRemoval {
    var firstError: DiskSnapshotError?
    if environment.diskSnapshots.mountedSnapshotName(at: mountPoint) == snapshot.name {
      do {
        try await environment.diskSnapshots.unmount(mountPoint)
      } catch {
        firstError = (error as? DiskSnapshotError) ?? .deleteFailed(String(describing: error))
      }
    }
    var deleted = false
    do {
      try await environment.diskSnapshots.delete(snapshot)
      deleted = true
    } catch {
      let mapped = (error as? DiskSnapshotError) ?? .deleteFailed(String(describing: error))
      if let dates = try? await environment.diskSnapshots.existingSnapshotDates(),
        !dates.contains(snapshot.date)
      {
        deleted = true
      } else if firstError == nil {
        firstError = mapped
      }
    }
    return SnapshotRemoval(error: firstError, deleted: deleted)
  }

  private func cleanUpStaleSnapshots(directory: URL) async -> [DiskSnapshotError] {
    let journal = directory.appendingPathComponent("pending.json")
    let mountPoint = directory.appendingPathComponent("Volume")
    var kept: [DiskSnapshot] = []
    var errors: [DiskSnapshotError] = []
    for entry in readJournal(journal) {
      let removal = await removeSnapshot(entry, mountPoint: mountPoint)
      if !removal.deleted {
        kept.append(entry)
      }
      if let error = removal.error {
        errors.append(error)
      }
    }
    try? writeJournal(kept, to: journal)
    return errors
  }

  public func cleanUpStaleDiskSnapshots() async {
    guard let directory = environment.snapshotDirectory, !running else { return }
    let task = Task {
      guard let lock = SnapshotLock.acquire(at: directory.appendingPathComponent("lock")) else {
        return
      }
      _ = await self.cleanUpStaleSnapshots(directory: directory)
      lock.release()
    }
    staleCleanupTask = task
    await task.value
    staleCleanupTask = nil
  }

  private static let snapshotMountSuffix = "/Library/Application Support/FUTO Backups/Snapshot/Volume"

  private func mapSnapshotPaths(_ snapshots: [Snapshot]) -> [Snapshot] {
    var mounts: [String] = []
    if let snapshotDirectory = environment.snapshotDirectory {
      let mount = snapshotDirectory.appendingPathComponent("Volume").path
      mounts = [mount, DataVolume.resolvedPath(mount)]
    }
    return snapshots.map { snapshot in
      guard snapshot.tags.contains("disk-snapshot") else { return snapshot }
      var copy = snapshot
      copy.paths = snapshot.paths.map { Self.livePath(of: $0, mounts: mounts) }
      return copy
    }
  }

  private static func livePath(of path: String, mounts: [String]) -> String {
    for mount in mounts {
      if let live = livePath(of: path, mountedAt: mount) {
        return live
      }
    }
    var searchStart = path.startIndex
    while let match = path.range(of: snapshotMountSuffix, range: searchStart..<path.endIndex) {
      if let live = livePath(of: path, mountedAt: String(path[..<match.upperBound])) {
        return live
      }
      searchStart = match.upperBound
    }
    return path
  }

  private static func livePath(of path: String, mountedAt mount: String) -> String? {
    if path == mount {
      return "/"
    }
    if path.hasPrefix(mount + "/") {
      return "/" + path.dropFirst(mount.count + 1)
    }
    return nil
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

  @discardableResult
  public func restore(
    config: AppConfig, snapshotId: String, items: [RestoreItem],
    onActivity: @escaping @Sendable (EngineActivity) -> Void
  ) async throws -> [URL] {
    if running {
      throw EngineError.busy
    }
    guard let repositoryId = config.repositoryId else {
      throw EngineError.noRepository
    }
    guard !items.isEmpty else {
      throw EngineError.noFolders
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
    var restored: [URL] = []
    for item in items {
      let target: URL
      let result: ResticResult
      do {
        target = try RestorePlan.claimTarget(
          for: item, avoiding: Set(restored.map { $0.lastPathComponent.lowercased() }),
          createDirectory: environment.createRestoreDirectory)
        result = try await environment.restic.run(
          ResticCommand.restore(
            session.context, snapshotId: snapshotId, subfolder: item.snapshotPath, target: target.path),
          onLine: { _ in })
      } catch {
        await session.proxy.stop()
        restoreData["error"] = .string(error is CancellationError ? "cancelled" : String(describing: error))
        await report(api, config: config, "Finished repository snapshot restore", restoreData)
        throw error
      }
      guard result.exitCode == ResticExitCode.success else {
        await session.proxy.stop()
        let detail = ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode)
        restoreData["error"] = .string(detail)
        await report(api, config: config, "Finished repository snapshot restore", restoreData)
        throw EngineError.restic(code: result.exitCode, message: detail)
      }
      restored.append(target)
    }
    await session.proxy.stop()
    await report(api, config: config, "Finished repository snapshot restore", restoreData)
    return restored
  }

  public func macRepositories(config: AppConfig) async throws -> [RemoteRepository] {
    let token = try accessToken()
    let server = try await serverInfo(for: config.serverURL)
    let api = environment.makeAPI(server.apiRoot, token)
    let repositories = try await api.listRepositories()
    return repositories.filter { $0.connectionType == "macos" }.sorted { lhs, rhs in
      let lhsIsThisMac = lhs.name == config.host
      if lhsIsThisMac != (rhs.name == config.host) {
        return lhsIsThisMac
      }
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

private final class BackupOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var storedSummary: BackupSummary?
  private var storedLastError: String?

  func record(_ message: ResticMessage) {
    lock.withLock {
      switch message {
      case .summary(let value): storedSummary = value
      case .error(let text): storedLastError = text
      case .status, .other: break
      }
    }
  }

  var summary: BackupSummary? {
    lock.withLock { storedSummary }
  }

  var lastError: String? {
    lock.withLock { storedLastError }
  }
}
