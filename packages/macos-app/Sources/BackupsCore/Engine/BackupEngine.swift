import Foundation

public actor BackupEngine {
  public static let keepWithin = "60d"

  private struct Session {
    var proxy: any ResticProxyHandle
    var context: ResticContext
  }

  private let environment: EngineEnvironment
  private var running = false
  private var serverCache: [URL: ServerInfo] = [:]
  private var futoResticCache: Bool?

  public init(environment: EngineEnvironment) {
    self.environment = environment
  }

  public func masterKey() throws -> String {
    if let stored = try environment.secrets.get(.masterKey) {
      return stored
    }
    let generated = RepositoryKeys.generateMasterKey()
    try environment.secrets.set(generated, for: .masterKey)
    return generated
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
    let created = try await api.createRepository(name: config.host)
    let session = try await startSession(config: config, repositoryId: created.id)
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
    running = true
    defer { running = false }
    let startedAt = environment.now()
    onActivity(.preparing)
    var status: BackupStatus = .failed
    var message: String?
    var summary: BackupSummary?
    var api: (any YuccaRepositoryAPI)?
    do {
      let server = try await serverInfo(for: config.serverURL)
      let madeAPI = environment.makeAPI(server.apiRoot, token)
      api = madeAPI
      try? await madeAPI.submitBackupStart(repositoryId: repositoryId)
      let session = try await startSession(config: config, repositoryId: repositoryId)
      do {
        _ = try await environment.restic.run(ResticCommand.unlock(session.context), onLine: { _ in })
        try Task.checkCancellation()
        let log = ResticLineLog()
        let result = try await environment.restic.run(
          ResticCommand.backup(
            session.context, paths: config.folders, excludes: config.excludes, host: config.host),
          onLine: { line in
            log.append(line)
            if case .status(let progress) = ResticOutput.parseLine(line) {
              onActivity(.backingUp(progress))
            }
          })
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
          do {
            let forget = try await environment.restic.run(
              ResticCommand.forget(session.context, host: config.host, keepWithin: Self.keepWithin),
              onLine: { _ in })
            if forget.exitCode != ResticExitCode.success {
              message =
                "Prune failed: "
                + ResticOutput.errorMessage(
                  stderr: forget.stderr, exitCode: forget.exitCode)
            }
          } catch {
            if error is CancellationError {
              throw error
            }
            message = "Prune failed: \(String(describing: error))"
          }
        }
        if status == .complete || status == .warn {
          if let stats = try? await environment.restic.run(ResticCommand.stats(session.context), onLine: { _ in }),
            stats.exitCode == ResticExitCode.success,
            let totalSize = try? ResticOutput.parseStatsTotalSize(stats.stdout)
          {
            try? await madeAPI.submitRepositorySize(repositoryId: repositoryId, sizeBytes: totalSize)
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
    if let api {
      try? await api.submitBackupEnd(repositoryId: repositoryId, status: status, durationMs: durationMs)
    }
    return RunRecord(
      startedAt: startedAt, finishedAt: finishedAt, status: status, snapshotId: summary?.snapshotId,
      filesNew: summary?.filesNew, dataAdded: summary?.dataAdded, message: message)
  }

  public func snapshots(config: AppConfig) async throws -> [Snapshot] {
    guard let repositoryId = config.repositoryId else {
      throw EngineError.noRepository
    }
    let session = try await startSession(config: config, repositoryId: repositoryId)
    let result: ResticResult
    do {
      result = try await environment.restic.run(ResticCommand.snapshots(session.context), onLine: { _ in })
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
    return try ResticOutput.parseSnapshots(result.stdout).sorted { $0.time > $1.time }
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
    running = true
    defer { running = false }
    let session = try await startSession(config: config, repositoryId: repositoryId)
    onActivity(.restoring)
    let result: ResticResult
    do {
      result = try await environment.restic.run(
        ResticCommand.restore(session.context, snapshotId: snapshotId, target: target.path, include: include),
        onLine: { _ in })
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
  }

  private func accessToken() throws -> String {
    guard let token = try environment.secrets.get(.accessToken) else {
      throw EngineError.notLoggedIn
    }
    return token
  }

  private func serverInfo(for url: URL) async throws -> ServerInfo {
    if let cached = serverCache[url] {
      return cached
    }
    let server = try await environment.discover(url)
    serverCache[url] = server
    return server
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

  private func startSession(config: AppConfig, repositoryId: String) async throws -> Session {
    let token = try accessToken()
    let server = try await serverInfo(for: config.serverURL)
    let proxy = try await environment.proxyLauncher.start(apiRoot: server.apiRoot, throttle: config.throttle)
    do {
      let context = ResticContext(
        repository: resticProxyRepositoryURL(
          address: proxy.address, repositoryId: repositoryId, accessToken: token),
        password: try RepositoryKeys.password(masterKey: try masterKey(), repositoryId: repositoryId),
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
