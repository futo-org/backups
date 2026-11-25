import Foundation
import Testing

@testable import BackupsCore

private let thisMac = RemoteRepository(id: "repo-mac", name: "Alice's Mac", worm: false, connectionId: "conn-mac")
private let otherMac = RemoteRepository(id: "repo-other", name: "Work Mac", worm: false, connectionId: "conn-work")
private let orphan = RemoteRepository(id: "repo-orphan", name: "Alice's Mac", worm: false, connectionId: "conn-mac")
private let connectionStillOwnsRepositories = YuccaError.http(
  status: 400, body: #"{"message":"Connection still owns repositories; adopt or delete them first"}"#)

private final class StepRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedSteps: [BackupDeletionStep] = []
  private var recordedOpened: [URL] = []

  var steps: [BackupDeletionStep] { lock.withLock { recordedSteps } }
  var opened: [URL] { lock.withLock { recordedOpened } }

  func step(_ step: BackupDeletionStep) {
    lock.withLock { recordedSteps.append(step) }
  }

  func open(_ url: URL) {
    lock.withLock { recordedOpened.append(url) }
  }
}

private func runDeletion(
  _ api: FakeAccountAPI,
  clock: FakeClock = FakeClock(),
  recorder: StepRecorder = StepRecorder(),
  telemetryVersion: String? = "1.2.3"
) async throws -> BackupDeletionResult {
  let deletion = BackupDeletion(
    api: api,
    openBrowser: { recorder.open($0) },
    telemetryVersion: telemetryVersion,
    sleep: { try clock.sleep($0) },
    elapsedNow: { clock.now })
  return try await deletion.run(repositoryId: thisMac.id) { recorder.step($0) }
}

@Test func happyPathWaitsForBrowserThenDeletesConnection() async throws {
  let api = FakeAccountAPI()
  await api.script(lists: [.success([thisMac, otherMac]), .success([thisMac, otherMac])], then: [otherMac])
  let clock = FakeClock()
  let recorder = StepRecorder()
  let result = try await runDeletion(api, clock: clock, recorder: recorder)
  #expect(result == .deleted)
  let ticketURL = await api.ticketURL
  #expect(recorder.opened == [ticketURL])
  #expect(recorder.steps == [.confirmingInBrowser(ticketURL), .removingThisMac])
  #expect(clock.sleeps == [BackupDeletion.pollInterval, BackupDeletion.pollInterval])
  #expect(
    await api.calls == [
      .me, .list, .log("Running repository deletion"), .createTicket(repositoryId: thisMac.id), .list, .list,
      .log("Finished repository deletion"), .deleteConnection("conn-mac"),
    ])
  let finished = try #require(await api.logs.last)
  #expect(finished.data["repositoryId"] == .string(thisMac.id))
  #expect(finished.data["error"] == nil)
}

@Test func omitsTelemetryWithoutConsent() async throws {
  let api = FakeAccountAPI()
  await api.script(lists: [.success([thisMac])], then: [])
  #expect(try await runDeletion(api, telemetryVersion: nil) == .deleted)
  #expect(await api.logs.isEmpty)
}

@Test func alreadyDeletedRepositorySkipsTheTicket() async throws {
  let api = FakeAccountAPI(repositories: [otherMac])
  let recorder = StepRecorder()
  let result = try await runDeletion(api, recorder: recorder)
  #expect(result == .deleted)
  #expect(recorder.opened.isEmpty)
  #expect(recorder.steps == [.removingThisMac])
  #expect(await api.calls == [.me, .list, .deleteConnection("conn-mac")])
}

@Test func userCancellingWhileWaitingDeletesNothing() async throws {
  let api = FakeAccountAPI(repositories: [thisMac])
  let clock = FakeClock(cancelAfterSleeps: 3)
  let recorder = StepRecorder()
  await #expect(throws: CancellationError.self) {
    _ = try await runDeletion(api, clock: clock, recorder: recorder)
  }
  let calls = await api.calls
  #expect(!calls.contains(.deleteConnection("conn-mac")))
  #expect(calls.filter { $0 == .list }.count == 3)
  #expect(recorder.steps == [.confirmingInBrowser(await api.ticketURL)])
  let finished = try #require(await api.logs.last)
  #expect(finished.summary == "Finished repository deletion")
  #expect(finished.data["error"] == .string("cancelled"))
}

@Test func timesOutAfterFifteenMinutesWithoutDeleting() async throws {
  let api = FakeAccountAPI(repositories: [thisMac])
  let clock = FakeClock()
  await #expect(throws: BackupDeletionError.timedOut) {
    _ = try await runDeletion(api, clock: clock)
  }
  #expect(clock.sleeps.reduce(.zero, +) == BackupDeletion.timeout)
  let calls = await api.calls
  #expect(!calls.contains(.deleteConnection("conn-mac")))
  let finished = try #require(await api.logs.last)
  #expect(finished.data["error"] == .string("timed out"))
}

@Test func connectionStillOwningRepositoriesListsThem() async throws {
  let api = FakeAccountAPI()
  await api.script(
    lists: [.success([thisMac, orphan, otherMac])], then: [orphan, otherMac],
    deleteConnectionErrors: [connectionStillOwnsRepositories])
  let result = try await runDeletion(api)
  #expect(result == .connectionKeepsRepositories([orphan]))
  let calls = await api.calls
  #expect(Array(calls.suffix(3)) == [.deleteConnection("conn-mac"), .list, .log("Failed to delete connection")])
  let failure = try #require(await api.logs.last)
  #expect(failure.data["connectionId"] == .string("conn-mac"))
  #expect(failure.data["repositories"] == .array([.string(orphan.id)]))
}

@Test func otherBadRequestIsAnUndeletedConnection() async throws {
  let api = FakeAccountAPI(repositories: [otherMac])
  await api.script(deleteConnectionErrors: [.http(status: 400, body: "Refusing to delete the default connection")])
  await #expect(throws: BackupDeletionError.connectionNotDeleted("Refusing to delete the default connection")) {
    _ = try await runDeletion(api)
  }
}

@Test func networkFailureCreatingTheTicketStopsBeforeTheBrowser() async throws {
  let api = FakeAccountAPI(repositories: [thisMac])
  await api.script(ticketError: .offline)
  let recorder = StepRecorder()
  await #expect(throws: AccountFakeError.offline) {
    _ = try await runDeletion(api, recorder: recorder)
  }
  #expect(recorder.opened.isEmpty)
  #expect(recorder.steps.isEmpty)
  #expect(!(await api.calls).contains(.deleteConnection("conn-mac")))
}

@Test func networkFailureWhilePollingKeepsWaiting() async throws {
  let api = FakeAccountAPI()
  await api.script(lists: [.success([thisMac]), .failure(.offline), .failure(.offline)], then: [])
  let clock = FakeClock()
  #expect(try await runDeletion(api, clock: clock) == .deleted)
  #expect(clock.sleeps.count == 3)
}

@Test func expiredSessionWhilePollingStops() async throws {
  let api = UnauthorizedListAPI()
  let deletion = BackupDeletion(
    api: api, openBrowser: { _ in }, telemetryVersion: nil, sleep: { _ in }, elapsedNow: { .now })
  await #expect(throws: YuccaError.unauthorized) {
    _ = try await deletion.run(repositoryId: thisMac.id) { _ in }
  }
}

@Test func networkFailureDeletingTheConnectionReportsTheBackupAsGone() async throws {
  let api = FakeAccountAPI()
  await api.script(
    lists: [.success([thisMac])], then: [], deleteConnectionErrors: [.http(status: 503, body: "unavailable")])
  await #expect(
    throws: BackupDeletionError.connectionNotDeleted(
      "The server returned an error (HTTP 503). Try again later.")
  ) {
    _ = try await runDeletion(api)
  }
  let summaries = await api.logs.map(\.summary)
  #expect(summaries == ["Running repository deletion", "Finished repository deletion"])
}

@Test func missingConnectionStopsBeforeAnything() async throws {
  let api = FakeAccountAPI(repositories: [thisMac])
  await api.setAccount(AuthInfo(id: "user-1", name: "Alice", email: "alice@example.com"))
  await #expect(throws: BackupDeletionError.noConnection) {
    _ = try await runDeletion(api)
  }
  #expect(await api.calls == [.me])
}

private actor UnauthorizedListAPI: AccountAPI {
  private var listed = false

  func me() async throws -> AuthInfo {
    AuthInfo(id: "u", name: "N", email: "e", connectionId: "conn-mac")
  }

  func logout() async throws {}

  func listRepositories() async throws -> [RemoteRepository] {
    guard !listed else { throw YuccaError.unauthorized }
    listed = true
    return [thisMac]
  }

  func createTicket(action: TicketAction, repositoryId: String) async throws -> URL {
    URL(string: "https://idp.example")!
  }

  func deleteConnection(id: String) async throws {
    Issue.record("must not delete the connection")
  }

  func submitStructuredLog(_ log: StructuredLog) async throws {}
}
