import Foundation

public protocol AccountAPI: Sendable {
  func me() async throws -> AuthInfo
  func logout() async throws
  func listRepositories() async throws -> [RemoteRepository]
  func createTicket(action: TicketAction, repositoryId: String) async throws -> URL
  func deleteConnection(id: String) async throws
  func submitStructuredLog(_ log: StructuredLog) async throws
}

extension YuccaClient: AccountAPI {}

public enum BackupDeletionStep: Equatable, Sendable {
  case confirmingInBrowser(URL)
  case removingThisMac
}

public enum BackupDeletionResult: Equatable, Sendable {
  case deleted
  case connectionKeepsRepositories([RemoteRepository])
}

public enum BackupDeletionError: Error, Equatable, Sendable {
  case noConnection
  case timedOut
  case connectionNotDeleted(String)
}

public struct BackupDeletion: Sendable {
  public static let pollInterval: Duration = .seconds(4)
  public static let timeout: Duration = .seconds(15 * 60)

  private let api: any AccountAPI
  private let openBrowser: @Sendable (URL) async -> Void
  private let sleep: @Sendable (Duration) async throws -> Void
  private let elapsedNow: @Sendable () -> ContinuousClock.Instant
  private let telemetryVersion: String?
  private let telemetryTimeout: Duration
  private let pollInterval: Duration
  private let timeout: Duration

  public init(
    api: any AccountAPI,
    openBrowser: @escaping @Sendable (URL) async -> Void,
    telemetryVersion: String?,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    elapsedNow: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
    telemetryTimeout: Duration = .seconds(10),
    pollInterval: Duration = BackupDeletion.pollInterval,
    timeout: Duration = BackupDeletion.timeout
  ) {
    self.api = api
    self.openBrowser = openBrowser
    self.telemetryVersion = telemetryVersion
    self.sleep = sleep
    self.elapsedNow = elapsedNow
    self.telemetryTimeout = telemetryTimeout
    self.pollInterval = pollInterval
    self.timeout = timeout
  }

  public func run(
    repositoryId: String,
    onStep: @escaping @Sendable (BackupDeletionStep) async -> Void
  ) async throws -> BackupDeletionResult {
    guard let connectionId = try await api.me().connectionId else {
      throw BackupDeletionError.noConnection
    }
    if try await isListed(repositoryId) {
      await report("Running repository deletion", ["repositoryId": .string(repositoryId)])
      do {
        try await deleteRepository(repositoryId, onStep: onStep)
      } catch {
        await report(
          "Finished repository deletion",
          ["repositoryId": .string(repositoryId), "error": .string(Self.telemetryError(error))])
        throw error
      }
      await report("Finished repository deletion", ["repositoryId": .string(repositoryId)])
    }
    await onStep(.removingThisMac)
    return try await deleteConnection(connectionId)
  }

  private func deleteRepository(
    _ repositoryId: String, onStep: @Sendable (BackupDeletionStep) async -> Void
  ) async throws {
    let url = try await api.createTicket(action: .deleteRepository, repositoryId: repositoryId)
    await openBrowser(url)
    await onStep(.confirmingInBrowser(url))
    let deadline = elapsedNow().advanced(by: timeout)
    while true {
      try await sleep(pollInterval)
      if try await isGone(repositoryId) {
        return
      }
      if elapsedNow() >= deadline {
        throw BackupDeletionError.timedOut
      }
    }
  }

  private func deleteConnection(_ connectionId: String) async throws -> BackupDeletionResult {
    do {
      try await api.deleteConnection(id: connectionId)
      return .deleted
    } catch YuccaError.http(status: 400, let body) {
      let owned = (try? await api.listRepositories())?.filter { $0.connectionId == connectionId } ?? []
      guard owned.isEmpty else {
        await report(
          "Failed to delete connection",
          ["connectionId": .string(connectionId), "repositories": .array(owned.map { .string($0.id) })])
        return .connectionKeepsRepositories(owned)
      }
      throw BackupDeletionError.connectionNotDeleted(body)
    } catch {
      throw BackupDeletionError.connectionNotDeleted(error.localizedDescription)
    }
  }

  private func isListed(_ repositoryId: String) async throws -> Bool {
    try await api.listRepositories().contains { $0.id == repositoryId }
  }

  private func isGone(_ repositoryId: String) async throws -> Bool {
    do {
      return try await !isListed(repositoryId)
    } catch YuccaError.unauthorized {
      throw YuccaError.unauthorized
    } catch {
      try Task.checkCancellation()
      return false
    }
  }

  private func report(_ summary: String, _ data: [String: TelemetryValue]) async {
    guard let telemetryVersion else { return }
    let log = StructuredLog(summary: summary, data: data, version: telemetryVersion)
    await bestEffort(within: telemetryTimeout) { [api] in
      try? await api.submitStructuredLog(log)
    }
  }

  private static func telemetryError(_ error: any Error) -> String {
    switch error {
    case is CancellationError: "cancelled"
    case BackupDeletionError.timedOut: "timed out"
    default: String(describing: error)
    }
  }
}

func bestEffort(within limit: Duration, _ work: @escaping @Sendable () async -> Void) async {
  // Unstructured so a cancelled deletion still reports why it stopped.
  await Task {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await work() }
      group.addTask { try? await Task.sleep(for: limit) }
      _ = await group.next()
      group.cancelAll()
    }
  }.value
}
