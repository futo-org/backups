import Foundation

@testable import BackupsCore

enum AccountCall: Equatable {
  case me
  case logout
  case list
  case createTicket(repositoryId: String)
  case deleteConnection(String)
  case log(String)
}

enum AccountFakeError: Error, Equatable {
  case offline
}

actor FakeAccountAPI: AccountAPI {
  private(set) var calls: [AccountCall] = []
  private(set) var logs: [StructuredLog] = []
  var account = AuthInfo(id: "user-1", name: "Alice", email: "alice@example.com", connectionId: "conn-mac")
  var listResults: [Result<[RemoteRepository], AccountFakeError>] = []
  var repositories: [RemoteRepository] = []
  var ticketURL = URL(string: "https://idp.example/authorize?state=s1")!
  var ticketError: AccountFakeError?
  var deleteConnectionErrors: [any Error] = []
  var logoutHangs = false
  var secretsAtLogout: [SecretKey: String]?
  private var secretsProbe: (@Sendable () -> [SecretKey: String])?

  init(repositories: [RemoteRepository] = []) {
    self.repositories = repositories
  }

  func script(
    lists: [Result<[RemoteRepository], AccountFakeError>] = [],
    then repositories: [RemoteRepository]? = nil,
    ticketError: AccountFakeError? = nil,
    deleteConnectionErrors: [any Error] = [],
    logoutHangs: Bool = false
  ) {
    listResults = lists
    if let repositories {
      self.repositories = repositories
    }
    self.ticketError = ticketError
    self.deleteConnectionErrors = deleteConnectionErrors
    self.logoutHangs = logoutHangs
  }

  func setAccount(_ value: AuthInfo) {
    account = value
  }

  func probeSecretsAtLogout(_ probe: @escaping @Sendable () -> [SecretKey: String]) {
    secretsProbe = probe
  }

  func me() async throws -> AuthInfo {
    calls.append(.me)
    return account
  }

  func logout() async throws {
    calls.append(.logout)
    secretsAtLogout = secretsProbe?()
    if logoutHangs {
      try await Task.sleep(for: .seconds(3600))
    }
  }

  func listRepositories() async throws -> [RemoteRepository] {
    calls.append(.list)
    if !listResults.isEmpty {
      return try listResults.removeFirst().get()
    }
    return repositories
  }

  func createTicket(action: TicketAction, repositoryId: String) async throws -> URL {
    calls.append(.createTicket(repositoryId: repositoryId))
    if let ticketError {
      throw ticketError
    }
    return ticketURL
  }

  func deleteConnection(id: String) async throws {
    calls.append(.deleteConnection(id))
    if !deleteConnectionErrors.isEmpty {
      throw deleteConnectionErrors.removeFirst()
    }
  }

  func submitStructuredLog(_ log: StructuredLog) async throws {
    calls.append(.log(log.summary))
    logs.append(log)
  }
}

final class FakeClock: @unchecked Sendable {
  private let lock = NSLock()
  private let start = ContinuousClock.now
  private var offset: Duration = .zero
  private var recorded: [Duration] = []
  private var cancelAfter: Int?

  init(cancelAfterSleeps: Int? = nil) {
    cancelAfter = cancelAfterSleeps
  }

  var now: ContinuousClock.Instant {
    lock.withLock { start.advanced(by: offset) }
  }

  var sleeps: [Duration] {
    lock.withLock { recorded }
  }

  func sleep(_ duration: Duration) throws {
    let shouldCancel = lock.withLock {
      recorded.append(duration)
      offset += duration
      return cancelAfter.map { recorded.count >= $0 } ?? false
    }
    if shouldCancel {
      withUnsafeCurrentTask { $0?.cancel() }
    }
    try Task.checkCancellation()
  }
}
