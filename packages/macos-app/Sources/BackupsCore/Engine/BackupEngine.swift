import Foundation

public actor BackupEngine {
  struct Session {
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

  let environment: EngineEnvironment
  private let outbox: Outbox
  var running = false
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

  public func setUpRepository(config: AppConfig, offeringExisting: Bool) async throws -> RepositorySetup {
    if offeringExisting, config.repositoryId == nil {
      let existing = try await macRepositories(config: config)
      if !existing.isEmpty, let masterKey = try storedMasterKey() {
        return .chooseExisting(existing, masterKey: masterKey)
      }
      try Task.checkCancellation()
    }
    return .ready(repositoryId: try await ensureRepository(config: config))
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
    let startedElapsed = environment.elapsedNow()
    onActivity(.preparing)
    var status: BackupStatus = .failed
    var message: String?
    var failureDetail: String?
    var caughtFailure: (any Error)?
    var summary: BackupSummary?
    var snapshotMounted = false
    var snapshotFailure: DiskSnapshotError?
    var api: (any YuccaRepositoryAPI)?
    var cloudOnlyScan: Task<CloudOnlySkip?, Never>?
    var warnings: BackupWarnings?
    let cloudOnlyScanFinished = OnceFlag()
    var everyFolderCloudOnly = false
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
        _ = try await runRestic(ResticCommand.unlock(session.context), interrupting: session.proxy)
        try Task.checkCancellation()
        let scanner = environment.cloudOnlyScanner
        let folders = config.folders.filter { !scanner.isCloudOnly($0) }
        let scanFinished = cloudOnlyScanFinished
        cloudOnlyScan = Task.detached(priority: environment.cloudOnlyScanPriority) {
          let result = await scanner.scan(folders: config.folders, excludes: config.excludes)
          scanFinished.set()
          return result
        }
        guard !folders.isEmpty else {
          everyFolderCloudOnly = true
          throw CloudOnlyError.everyFolderIsCloudOnly
        }
        let relatives = folders.map { environment.dataVolumePath($0) }
        let snapshotMode = config.usesDiskSnapshots && relatives.contains { $0 != nil }
        var createdSnapshot: DiskSnapshot?
        var snapshotMountPoint: URL?
        var snapshotJournal: URL?
        var snapshotLock: SnapshotLock?
        var mounted = false
        var snapshotCleanedUp = false
        var backupPaths = folders
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
            do {
              try writeJournal(
                readJournal(snapshotJournal).filter { $0 != createdSnapshot }, to: snapshotJournal)
            } catch {
              await report(
                madeAPI, config: config, "Failed to remove disk snapshot",
                [
                  "repositoryId": .string(repositoryId),
                  "error": .string(
                    (error as? DiskSnapshotError)?.telemetryCode ?? String(describing: type(of: error))),
                ])
            }
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
            let pending = try readJournal(journal)
            let snapshot = try await Task {
              try await self.environment.diskSnapshots.create()
            }.value
            createdSnapshot = snapshot
            do {
              try writeJournal(pending + [snapshot], to: journal)
            } catch {
              throw DiskSnapshotError.createFailed("could not record the snapshot")
            }
            try Task.checkCancellation()
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
            for index in folders.indices {
              snapshotPaths.append(relatives[index] ?? folders[index])
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
          result = try await runBackupCommand(
            ResticCommand.backup(
              session.context, paths: backupPaths, excludes: backupExcludes, host: config.host,
              currentDirectory: backupCurrentDirectory, tags: backupTags),
            proxy: session.proxy, throttle: config.throttle, output: output, onActivity: onActivity)
        } catch {
          await runSnapshotCleanup()
          snapshotLock?.release()
          snapshotLock = nil
          throw error
        }
        if createdSnapshot != nil, !snapshotCleanedUp {
          onActivity(.finishing(.removingDiskSnapshot))
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
          let snapshotMounts = [backupCurrentDirectory, snapshotMountPoint?.path].compactMap { $0 }
          let collected = BackupWarnings.collect(stderr: result.stderr, snapshotMounts: snapshotMounts)
          warnings = collected
          message =
            collected.summary
            ?? BackupWarnings.livePaths(
              in: ResticOutput.lastItemError(stderr: result.stderr) ?? lastError
                ?? ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode),
              snapshotMounts: snapshotMounts)
        } else {
          status = .failed
          let detail = ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode)
          message = ErrorMessage.resticText(detail, server: config.serverDisplayName)
          failureDetail = detail
        }
        var pruneInterrupted = false
        let retention = config.snapshotRetention
        let forgetInvocation = ResticCommand.forget(session.context, host: config.host, retention: retention)
        if status == .complete, case .policy = retention, forgetInvocation == nil {
          message = "Old snapshots were kept: the snapshot retention setting is invalid"
          await report(
            madeAPI, config: config, "Skipped repository prune",
            ["repositoryId": .string(repositoryId), "error": .string("invalid retention policy")])
        }
        if status == .complete, let forgetInvocation {
          onActivity(.pruning)
          await report(
            madeAPI, config: config, "Running repository prune",
            [
              "repositoryId": .string(repositoryId),
              "retentionPolicy": .string(retention.telemetryValue),
            ])
          var pruneError: String?
          do {
            let forget = try await runRestic(forgetInvocation, interrupting: session.proxy)
            if forget.exitCode != ResticExitCode.success {
              let detail = ResticOutput.errorMessage(
                stderr: forget.stderr, exitCode: forget.exitCode)
              pruneError = detail
              message = "Prune failed: " + detail
            }
          } catch is CancellationError {
            pruneInterrupted = true
            pruneError = "cancelled"
            message = "Prune interrupted"
          } catch {
            pruneError = String(describing: error)
            message = "Prune failed: \(error.localizedDescription)"
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
        if (status == .complete || status == .warn) && !pruneInterrupted {
          var totalSize: Int64?
          var statsError: String?
          do {
            let stats = try await runRestic(
              ResticCommand.stats(session.context), interrupting: session.proxy)
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
      if error is CancellationError || (Task.isCancelled && ErrorMessage.isCancellation(error)) {
        status = .cancelled
      } else {
        status = .failed
        message =
          ErrorMessage.text(for: error, server: config.serverDisplayName)
          ?? ConnectionFailure.unreachable.message(server: config.serverDisplayName)
        failureDetail = String(describing: error)
        caughtFailure = error
      }
    }
    var cloudOnlySkipped: CloudOnlySkip?
    if let cloudOnlyScan {
      if status == .complete || status == .warn || everyFolderCloudOnly {
        if !cloudOnlyScanFinished.isSet {
          onActivity(.finishing(.checkingCloudOnlyFiles))
        }
        cloudOnlySkipped = await withTaskCancellationHandler {
          await cloudOnlyScan.value
        } onCancel: {
          cloudOnlyScan.cancel()
        }
      } else {
        cloudOnlyScan.cancel()
      }
    }
    let finishedAt = environment.now()
    let durationMs = Int(startedElapsed.duration(to: environment.elapsedNow()) / .milliseconds(1))
    let endStatus = status
    let endMessage = (status == .failed || status == .warn) ? message : nil
    let keptWarnings = status == .warn ? warnings.flatMap { $0.total > 0 ? $0 : nil } : nil
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
      if let cloudOnlySkipped {
        data["cloudOnlyFiles"] = .int(Int64(cloudOnlySkipped.count))
        data["cloudOnlySize"] = .string(cloudOnlySkipped.telemetrySizeBucket)
      }
      if let keptWarnings {
        data["warningCount"] = .int(Int64(keptWarnings.total))
      }
      if let snapshotFailure {
        data["error"] = .string("disk snapshot: \(snapshotFailure.telemetryCode)")
      } else if let endMessage {
        data["error"] = .string(failureDetail ?? endMessage)
      }
      await report(endAPI, config: config, "Backup finished", data)
    } else if let caughtFailure {
      environment.logUnreportedFailure(caughtFailure)
    }
    return RunRecord(
      startedAt: startedAt, finishedAt: finishedAt, status: status, snapshotId: summary?.snapshotId,
      filesNew: summary?.filesNew, dataAdded: summary?.dataAdded, message: message,
      cloudOnlySkipped: cloudOnlySkipped.flatMap { $0.count > 0 ? $0 : nil }, warnings: keptWarnings)
  }

  private func runBackupCommand(
    _ invocation: ResticInvocation, proxy: any ResticProxyHandle, throttle: Throttle, output: BackupOutput,
    onActivity: @escaping @Sendable (EngineActivity) -> Void
  ) async throws -> ResticResult {
    let tracker = BackingUpActivity(throttle: throttle)
    let ticks = environment.uploadTicks()
    let sampler = Task.detached {
      for await instant in ticks {
        if let activity = tracker.sampled(proxy.uploadedBytes, at: instant) {
          onActivity(activity)
        }
      }
    }
    do {
      let result = try await runRestic(
        invocation, interrupting: proxy,
        onLine: { line in
          let message = ResticOutput.parseLine(line)
          if case .status(let progress) = message {
            onActivity(tracker.progressed(progress))
          } else {
            output.record(message)
          }
        })
      sampler.cancel()
      await sampler.value
      return result
    } catch {
      sampler.cancel()
      await sampler.value
      throw error
    }
  }

  private func runRestic(
    _ invocation: ResticInvocation, interrupting proxy: any ResticProxyHandle,
    onLine: @escaping @Sendable (String) -> Void = { _ in }
  ) async throws -> ResticResult {
    let restic = environment.restic
    return try await withTaskCancellationHandler {
      try await restic.run(invocation, onLine: onLine)
    } onCancel: {
      try? proxy.networkChanged()
    }
  }

  private func readJournal(_ url: URL) throws -> [DiskSnapshot] {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      if isMissingFile(error) {
        return []
      }
      throw DiskSnapshotError.journalUnreadable
    }
    do {
      return try JSONDecoder().decode([DiskSnapshot].self, from: data)
    } catch {
      throw DiskSnapshotError.journalUnreadable
    }
  }

  private func writeJournal(_ entries: [DiskSnapshot], to url: URL) throws {
    if entries.isEmpty {
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        if !isMissingFile(error) {
          throw error
        }
      }
      return
    }
    try JSONEncoder().encode(entries).write(to: url, options: .atomic)
  }

  private func isMissingFile(_ error: any Error) -> Bool {
    let nsError = error as NSError
    let cocoaNotFound =
      nsError.domain == NSCocoaErrorDomain
      && (nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError)
    let posixNotFound = (error as? POSIXError).map { $0.code.rawValue == Int32(ENOENT) } ?? false
    return cocoaNotFound || posixNotFound
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
    let entries: [DiskSnapshot]
    do {
      entries = try readJournal(journal)
    } catch {
      return [(error as? DiskSnapshotError) ?? .journalUnreadable]
    }
    var kept: [DiskSnapshot] = []
    var errors: [DiskSnapshotError] = []
    for entry in entries {
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

  public func listDirectory(config: AppConfig, snapshotId: String, path: String) async throws -> [SnapshotEntry] {
    guard let repositoryId = config.repositoryId else {
      throw EngineError.noRepository
    }
    let token = try accessToken()
    let session = try await startSession(
      config: config, repositoryId: repositoryId, masterKey: try requireMasterKey(), token: token)
    let server = try await serverInfo(for: config.serverURL)
    let api = environment.makeAPI(server.apiRoot, token)
    do {
      let result = try await runRestic(
        ResticCommand.ls(session.context, snapshotId: snapshotId, directory: path), interrupting: session.proxy)
      guard result.exitCode == ResticExitCode.success else {
        throw EngineError.restic(
          code: result.exitCode, message: ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode))
      }
      let entries = try SnapshotListing.parse(result.stdout, directory: path)
      await session.proxy.stop()
      return entries
    } catch {
      await session.proxy.stop()
      if !(error is CancellationError) {
        await report(
          api, config: config, "Failed to list snapshot files",
          [
            "repositoryId": .string(repositoryId), "snapshotId": .string(snapshotId),
            "error": .string(telemetryDescription(error)),
          ])
      }
      throw error
    }
  }

  @discardableResult
  public func restore(
    config: AppConfig, snapshotId: String, items: [RestoreItem],
    onActivity: @escaping @Sendable (EngineActivity) -> Void
  ) async throws -> [URL] {
    try await restoring(config: config, snapshotId: snapshotId, isEmpty: items.isEmpty) { session in
      try await self.collectingRestored { restored in
        for (index, item) in items.enumerated() {
          let reporter = RestoreReporter(
            part: index + 1, of: items.count, batch: .folder(item), onActivity: onActivity)
          restored.append(
            try await self.restoreFolder(
              item, snapshotId: snapshotId, session: session, reporter: reporter, avoiding: restored.names))
        }
      }
    }
  }

  @discardableResult
  public func restore(
    config: AppConfig, snapshotId: String, selection: [SnapshotEntry], into target: URL,
    onActivity: @escaping @Sendable (EngineActivity) -> Void
  ) async throws -> [URL] {
    try await restoring(
      config: config, snapshotId: snapshotId, isEmpty: selection.isEmpty,
      extraData: ["itemCount": .int(Int64(selection.count))]
    ) { session in
      try await self.collectingRestored { restored in
        let batches = RestorePlan.batches(for: selection, into: target)
        for (index, batch) in batches.enumerated() {
          let reporter = RestoreReporter(part: index + 1, of: batches.count, batch: batch, onActivity: onActivity)
          switch batch {
          case .folder(let item):
            restored.append(
              try await self.restoreFolder(
                item, snapshotId: snapshotId, session: session, reporter: reporter, avoiding: restored.names))
          case .children(let children, let parent):
            try await self.restoreChildren(
              children, of: parent, into: target, snapshotId: snapshotId, session: session, reporter: reporter,
              restored: &restored)
          }
        }
      }
    }
  }

  private func collectingRestored(_ body: (inout RestoredItems) async throws -> Void) async throws -> [URL] {
    var restored = RestoredItems()
    do {
      try await body(&restored)
    } catch var incomplete as RestoreIncomplete {
      incomplete.restored = restored.urls
      throw incomplete
    } catch let error where !restored.urls.isEmpty {
      throw RestoreIncomplete(restored: restored.urls, cause: error)
    }
    return restored.urls
  }

  private func restoring(
    config: AppConfig, snapshotId: String, isEmpty: Bool,
    extraData: [String: TelemetryValue] = [:],
    _ body: (Session) async throws -> [URL]
  ) async throws -> [URL] {
    if running {
      throw EngineError.busy
    }
    guard let repositoryId = config.repositoryId else {
      throw EngineError.noRepository
    }
    guard !isEmpty else {
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
    var restoreData: [String: TelemetryValue] = [
      "repositoryId": .string(repositoryId),
      "snapshotId": .string(snapshotId),
    ].merging(extraData) { current, _ in current }
    await report(api, config: config, "Running repository snapshot restore", restoreData)
    let restored: [URL]
    do {
      restored = try await body(session)
    } catch {
      await session.proxy.stop()
      restoreData["error"] = .string(telemetryDescription(error))
      await report(api, config: config, "Finished repository snapshot restore", restoreData)
      throw error
    }
    await session.proxy.stop()
    await report(api, config: config, "Finished repository snapshot restore", restoreData)
    return restored
  }

  private func restoreFolder(
    _ item: RestoreItem, snapshotId: String, session: Session, reporter: RestoreReporter,
    avoiding taken: Set<String>
  ) async throws -> URL {
    let target = try RestorePlan.claimTarget(
      for: item, avoiding: taken, createDirectory: environment.createRestoreDirectory)
    try await runRestore(
      ResticCommand.restore(
        session.context, snapshotId: snapshotId, subfolder: item.snapshotPath, target: target.path),
      session: session, reporter: reporter)
    reporter.finished()
    return target
  }

  private func restoreChildren(
    _ children: [SnapshotEntry], of parent: String, into target: URL, snapshotId: String, session: Session,
    reporter: RestoreReporter, restored: inout RestoredItems
  ) async throws {
    let staging = try RestorePlan.claimStaging(
      in: target, avoiding: Set(children.map { RestorePlan.nameKey($0.name) }),
      createDirectory: environment.createRestoreStaging)
    do {
      try await runRestore(
        ResticCommand.restore(
          session.context, snapshotId: snapshotId, subfolder: parent, target: staging.path,
          includingChildren: children.map(\.name)),
        session: session, reporter: reporter)
      for child in children {
        let source = staging.appendingPathComponent(child.name)
        restored.append(
          try RestorePlan.claimName(for: child, in: target, avoiding: restored.names) {
            try self.environment.moveRestoredItem(source, $0)
          })
      }
    } catch {
      try removeStaging(staging, after: error)
      throw error
    }
    try removeStaging(staging, after: nil)
    reporter.finished()
  }

  private func removeStaging(_ staging: URL, after failure: (any Error)?) throws {
    do {
      try environment.removeRestoreStaging(staging)
    } catch {
      throw RestoreIncomplete(restored: [], leftoverStaging: staging, cause: failure ?? error)
    }
  }

  private func runRestore(_ invocation: ResticInvocation, session: Session, reporter: RestoreReporter) async throws {
    reporter.started()
    let result = try await runRestic(invocation, interrupting: session.proxy, onLine: reporter.received)
    guard result.exitCode == ResticExitCode.success else {
      throw EngineError.restic(
        code: result.exitCode, message: ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode))
    }
  }

  private func telemetryDescription(_ error: any Error) -> String {
    switch error {
    case is CancellationError: return "cancelled"
    case EngineError.restic(_, let message): return message
    case let incomplete as RestoreIncomplete: return telemetryDescription(incomplete.cause)
    default: return String(describing: error)
    }
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

  public func unlockExistingRepository(
    _ repositoryId: String, with key: ExistingBackupKey, config: AppConfig
  ) async throws -> ExistingBackupUnlock {
    switch key {
    case .stored(let stored):
      guard try await verifyMasterKey(stored, config: config, repositoryId: repositoryId) else { return .needsKey }
      try importMasterKey(stored)
    case .entered(let entered):
      guard try await verifyMasterKey(entered, config: config, repositoryId: repositoryId) else { return .wrongKey }
      try importMasterKey(entered)
    }
    return .unlocked
  }

  public func checkStoredKey(
    _ storedKey: String, against repositoryIds: [String], config: AppConfig,
    onCheck: @escaping @Sendable (String, StoredKeyCheck) async -> Void
  ) async {
    for repositoryId in repositoryIds {
      guard !Task.isCancelled else { return }
      await onCheck(repositoryId, .checking)
      guard !Task.isCancelled else { return }
      let check: StoredKeyCheck
      do {
        check =
          try await verifyMasterKey(storedKey, config: config, repositoryId: repositoryId) ? .opens : .doesNotOpen
      } catch {
        check = .unknown
      }
      guard !Task.isCancelled else { return }
      await onCheck(repositoryId, check)
    }
  }

  func accessToken() throws -> String {
    guard let token = try environment.secrets.get(.accessToken) else {
      throw EngineError.notLoggedIn
    }
    return token
  }

  func requireMasterKey() throws -> String {
    guard let masterKey = try storedMasterKey() else {
      throw EngineError.missingMasterKey
    }
    return masterKey
  }

  func serverInfo(for url: URL) async throws -> ServerInfo {
    if let cached = serverCache[url] {
      return cached
    }
    let server = try await environment.discover(url)
    serverCache[url] = server
    return server
  }

  func report(
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

  func startSession(
    config: AppConfig, repositoryId: String, masterKey: String, token: String
  ) async throws -> Session {
    let server = try await serverInfo(for: config.serverURL)
    let proxy = NetworkWatchedProxy(
      try await environment.proxyLauncher.start(apiRoot: server.apiRoot, throttle: config.throttle),
      changes: environment.networkChanges())
    do {
      let context = ResticContext(
        repository: resticProxyRepositoryURL(
          address: proxy.address, repositoryId: repositoryId, accessToken: token),
        password: try RepositoryKeys.password(masterKey: masterKey, repositoryId: repositoryId),
        cacheDirectory: environment.cacheDirectory,
        home: environment.home,
        connections: config.uploadConnections.map { max(1, $0) }
          ?? max(1, Int(server.connectionsMath.trimmingCharacters(in: .whitespaces)) ?? environment.processorCount),
        packSizeMiB: min(
          max(server.resticPackSizeMiB, ResticContext.packSizeRangeMiB.lowerBound),
          ResticContext.packSizeRangeMiB.upperBound),
        walkConcurrency: await isFutoRestic() ? 64 : nil,
        readConcurrency: config.readConcurrency.map { max(1, $0) })
      return Session(proxy: proxy, context: context)
    } catch {
      await proxy.stop()
      throw error
    }
  }
}

final class NetworkWatchedProxy: ResticProxyHandle {
  private let proxy: any ResticProxyHandle
  private let watcher: Task<Void, Never>

  init(_ proxy: any ResticProxyHandle, changes: AsyncStream<Void>) {
    self.proxy = proxy
    watcher = Task.detached {
      for await _ in changes {
        try? proxy.networkChanged()
      }
    }
  }

  var address: String { proxy.address }

  var uploadedBytes: Int64 { proxy.uploadedBytes }

  func setThrottle(_ throttle: Throttle) throws {
    try proxy.setThrottle(throttle)
  }

  func networkChanged() throws {
    try proxy.networkChanged()
  }

  func stop() async {
    watcher.cancel()
    await proxy.stop()
  }
}

final class BackingUpActivity: @unchecked Sendable {
  private let lock = NSLock()
  private var meter: UploadSpeedMeter
  private var progress: BackupProgress?

  init(throttle: Throttle) {
    meter = UploadSpeedMeter(throttle: throttle)
  }

  func progressed(_ progress: BackupProgress) -> EngineActivity {
    lock.withLock {
      self.progress = progress
      return .backingUp(progress, meter.speed)
    }
  }

  func sampled(_ uploadedBytes: Int64, at instant: ContinuousClock.Instant) -> EngineActivity? {
    lock.withLock {
      let speed = meter.record(uploadedBytes, at: instant)
      return progress.map { .backingUp($0, speed) }
    }
  }
}

final class RestoreReporter: @unchecked Sendable {
  private let step: RestoreStep
  private let onActivity: @Sendable (EngineActivity) -> Void
  private let lock = NSLock()
  private var summary: RestoreProgress?

  init(part: Int, of partCount: Int, batch: RestoreBatch, onActivity: @escaping @Sendable (EngineActivity) -> Void) {
    step = RestoreStep(part: part, partCount: partCount, name: batch.name)
    self.onActivity = onActivity
  }

  func started() {
    onActivity(.restoring(step))
  }

  func received(_ line: String) {
    switch RestoreMessage.parse(line) {
    case .status(let progress): report(progress)
    case .summary(let progress): lock.withLock { summary = progress }
    case nil: break
    }
  }

  func finished() {
    guard let summary = lock.withLock({ summary }) else { return }
    report(summary)
  }

  private func report(_ progress: RestoreProgress) {
    var step = step
    step.progress = progress
    onActivity(.restoring(step))
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
