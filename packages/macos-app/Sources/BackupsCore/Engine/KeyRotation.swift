import Darwin
import Foundation

public struct PendingKeyRotation: Codable, Equatable, Sendable {
  public var repositoryId: String
  public var oldKeyId: String
  public var previousMasterKey: String
  public var newMasterKey: String
}

public enum KeyRotationError: Error, Equatable, Sendable {
  case currentKeyNotFound
  case newKeyRejected
  case passwordFileFailed
  case pendingRotationUnreadable
}

public enum KeyRotationOutcome: Equatable, Sendable {
  case complete
  case oldKeyRemovalPending
}

private enum KeyRotationStage: String {
  case resume
  case list
  case add
  case verify
  case store
  case remove
}

extension BackupEngine {
  static let passwordDirectoryPrefix = "futo-backups-key-"

  public func changeMasterKey(to input: String, config: AppConfig) async throws -> KeyRotationOutcome {
    if running {
      throw EngineError.busy
    }
    guard let newMasterKey = RepositoryKeys.normalizedMasterKey(input) else {
      throw RepositoryKeysError.invalidMasterKey
    }
    guard let repositoryId = config.repositoryId else {
      throw EngineError.noRepository
    }
    let token = try accessToken()
    _ = try requireMasterKey()
    running = true
    defer { running = false }
    let server = try await serverInfo(for: config.serverURL)
    let api = environment.makeAPI(server.apiRoot, token)
    removeStalePasswordDirectories()
    var stage = KeyRotationStage.resume
    do {
      try await completePendingKeyRotation(config: config, token: token)
      let oldMasterKey = try requireMasterKey()
      guard oldMasterKey != newMasterKey else {
        return .complete
      }
      stage = .list
      let oldSession = try await startSession(
        config: config, repositoryId: repositoryId, masterKey: oldMasterKey, token: token)
      let oldKeyId: String
      do {
        oldKeyId = try await currentKeyId(oldSession.context)
        stage = .add
        try await addKey(
          oldSession.context,
          password: try RepositoryKeys.password(masterKey: newMasterKey, repositoryId: repositoryId))
      } catch {
        await oldSession.proxy.stop()
        throw error
      }
      await oldSession.proxy.stop()
      stage = .verify
      let newSession = try await startSession(
        config: config, repositoryId: repositoryId, masterKey: newMasterKey, token: token)
      var removalError: (any Error)?
      do {
        try await verifyOpens(newSession.context)
        stage = .store
        try commit(
          PendingKeyRotation(
            repositoryId: repositoryId, oldKeyId: oldKeyId, previousMasterKey: oldMasterKey,
            newMasterKey: newMasterKey))
        stage = .remove
        do {
          try await removeKey(oldKeyId, context: newSession.context)
          try environment.secrets.delete(.pendingKeyRotation)
        } catch {
          removalError = error
        }
      } catch {
        await newSession.proxy.stop()
        throw error
      }
      await newSession.proxy.stop()
      var data: [String: TelemetryValue] = [
        "repositoryId": .string(repositoryId),
        "oldKeyRemoved": .bool(removalError == nil),
      ]
      if let removalError {
        data["error"] = .string(keyRotationErrorCode(removalError))
      }
      await report(api, config: config, "Changed recovery key", data)
      return removalError == nil ? .complete : .oldKeyRemovalPending
    } catch {
      await report(
        api, config: config, "Changed recovery key",
        [
          "repositoryId": .string(repositoryId),
          "stage": .string(stage.rawValue),
          "error": .string(keyRotationErrorCode(error)),
        ])
      throw error
    }
  }

  @discardableResult
  public func finishPendingKeyRotation(config: AppConfig) async throws -> Bool {
    guard let pending = try loadPendingKeyRotation() else {
      return false
    }
    if running {
      throw EngineError.busy
    }
    let token = try accessToken()
    running = true
    defer { running = false }
    let server = try await serverInfo(for: config.serverURL)
    let api = environment.makeAPI(server.apiRoot, token)
    removeStalePasswordDirectories()
    do {
      guard try await completePendingKeyRotation(config: config, token: token) else {
        return false
      }
    } catch {
      await report(
        api, config: config, "Finished recovery key change",
        ["repositoryId": .string(pending.repositoryId), "error": .string(keyRotationErrorCode(error))])
      throw error
    }
    await report(
      api, config: config, "Finished recovery key change", ["repositoryId": .string(pending.repositoryId)])
    return true
  }

  @discardableResult
  private func completePendingKeyRotation(config: AppConfig, token: String) async throws -> Bool {
    guard let pending = try loadPendingKeyRotation() else {
      return false
    }
    let stored = try environment.secrets.get(.masterKey)
    let superseded = stored != nil && stored != pending.previousMasterKey && stored != pending.newMasterKey
    guard pending.repositoryId == config.repositoryId, !superseded else {
      try environment.secrets.delete(.pendingKeyRotation)
      return false
    }
    if stored != pending.newMasterKey {
      try environment.secrets.set(pending.newMasterKey, for: .masterKey)
    }
    let session = try await startSession(
      config: config, repositoryId: pending.repositoryId, masterKey: pending.newMasterKey, token: token)
    do {
      try await removeKey(pending.oldKeyId, context: session.context)
    } catch {
      await session.proxy.stop()
      throw error
    }
    await session.proxy.stop()
    try environment.secrets.delete(.pendingKeyRotation)
    return true
  }

  private func loadPendingKeyRotation() throws -> PendingKeyRotation? {
    guard let stored = try environment.secrets.get(.pendingKeyRotation) else {
      return nil
    }
    do {
      return try JSONDecoder().decode(PendingKeyRotation.self, from: Data(stored.utf8))
    } catch {
      throw KeyRotationError.pendingRotationUnreadable
    }
  }

  private func commit(_ pending: PendingKeyRotation) throws {
    let encoded = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
    try environment.secrets.set(encoded, for: .pendingKeyRotation)
    do {
      try environment.secrets.set(pending.newMasterKey, for: .masterKey)
    } catch {
      try? environment.secrets.delete(.pendingKeyRotation)
      throw error
    }
  }

  private func currentKeyId(_ context: ResticContext) async throws -> String {
    guard let current = try await listKeys(context).first(where: \.current) else {
      throw KeyRotationError.currentKeyNotFound
    }
    return current.id
  }

  private func listKeys(_ context: ResticContext) async throws -> [ResticKey] {
    try ResticOutput.parseKeys(try await runChecked(ResticCommand.keyList(context)).stdout)
  }

  private func removeKey(_ id: String, context: ResticContext) async throws {
    guard try await listKeys(context).contains(where: { $0.id == id }) else {
      return
    }
    try await runChecked(ResticCommand.keyRemove(context, id: id))
  }

  private func verifyOpens(_ context: ResticContext) async throws {
    let result = try await environment.restic.run(ResticCommand.catConfig(context), onLine: { _ in })
    if result.exitCode == ResticExitCode.wrongPassword {
      throw KeyRotationError.newKeyRejected
    }
    try requireSuccess(result)
  }

  private func addKey(_ context: ResticContext, password: String) async throws {
    let directory = environment.temporaryDirectory.appendingPathComponent(
      Self.passwordDirectoryPrefix + UUID().uuidString)
    guard mkdir(directory.path, 0o700) == 0 else {
      throw KeyRotationError.passwordFileFailed
    }
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("password")
    try writePrivately(password, to: file)
    try await runChecked(ResticCommand.keyAdd(context, newPasswordFile: file.path))
  }

  private func writePrivately(_ text: String, to url: URL) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw KeyRotationError.passwordFileFailed
    }
    defer { close(descriptor) }
    let bytes = Array(text.utf8)
    let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == bytes.count else {
      throw KeyRotationError.passwordFileFailed
    }
  }

  private func removeStalePasswordDirectories() {
    let fileManager = FileManager.default
    let root = environment.temporaryDirectory
    guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
      return
    }
    for name in names where name.hasPrefix(Self.passwordDirectoryPrefix) {
      try? fileManager.removeItem(at: root.appendingPathComponent(name))
    }
  }

  @discardableResult
  private func runChecked(_ invocation: ResticInvocation) async throws -> ResticResult {
    let result = try await environment.restic.run(invocation, onLine: { _ in })
    try requireSuccess(result)
    return result
  }

  private func requireSuccess(_ result: ResticResult) throws {
    guard result.exitCode == ResticExitCode.success else {
      throw EngineError.restic(
        code: result.exitCode,
        message: ResticOutput.errorMessage(stderr: result.stderr, exitCode: result.exitCode))
    }
  }

  private func keyRotationErrorCode(_ error: any Error) -> String {
    if case .restic(let code, _) = error as? EngineError {
      return "restic exit \(code)"
    }
    if error is CancellationError {
      return "cancelled"
    }
    if error is EngineError || error is KeyRotationError || error is SecretStoreError
      || error is RepositoryKeysError
    {
      return String(describing: error)
    }
    return String(describing: type(of: error))
  }
}
