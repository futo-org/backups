import Foundation
import Testing

@testable import BackupsCore

private struct Sandbox {
  let home: URL
  let files: LocalFiles
  let unrelated: URL

  init() throws {
    home = FileManager.default.temporaryDirectory.appendingPathComponent("mac-reset-\(UUID().uuidString)")
    files = LocalFiles.standard(home: home)
    let applicationSupport = files.configFile.deletingLastPathComponent()
    unrelated = applicationSupport.appendingPathComponent("notes.txt")
    try write(files.configFile)
    try write(applicationSupport.appendingPathComponent("config.json.corrupt-2026-06-10T120000Z"))
    try write(unrelated)
    try write(files.cacheDirectory.appendingPathComponent("restic/abc/index/0001"))
    try write(files.snapshotDirectory.appendingPathComponent("pending.json"))
    try write(files.snapshotDirectory.appendingPathComponent("lock"))
    try FileManager.default.createDirectory(
      at: files.snapshotDirectory.appendingPathComponent("Volume"), withIntermediateDirectories: true)
  }

  func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: home)
  }

  private func write(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
  }
}

private final class FailingSecretStore: SecretStore, @unchecked Sendable {
  func get(_ key: SecretKey) throws -> String? { "value" }
  func set(_ value: String, for key: SecretKey) throws {}
  func delete(_ key: SecretKey) throws {
    if key == .masterKey {
      throw SecretStoreError.keychain(-25300)
    }
  }
}

private func allSecrets(_ store: InMemorySecretStore) -> [SecretKey: String] {
  var values: [SecretKey: String] = [:]
  for key in SecretKey.allCases {
    values[key] = try? store.get(key)
  }
  return values
}

@Test func standardFilesMatchTheAppLocations() {
  let files = LocalFiles.standard(home: URL(fileURLWithPath: "/Users/alice"))
  #expect(files.configFile.path == "/Users/alice/Library/Application Support/FUTO Backups/config.json")
  #expect(files.cacheDirectory.path == "/Users/alice/Library/Caches/FUTO Backups")
  #expect(files.snapshotDirectory.path == "/Users/alice/Library/Application Support/FUTO Backups/Snapshot")
}

@Test func resetRemovesSecretsConfigCacheAndSnapshotFiles() async throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let secrets = InMemorySecretStore([.accessToken: "tok", .masterKey: String(repeating: "a", count: 64)])
  let reset = MacReset(files: sandbox.files, secrets: secrets, cleanUpDiskSnapshots: {})
  let failed = await reset.run()
  #expect(failed.isEmpty)
  #expect(allSecrets(secrets).isEmpty)
  #expect(!sandbox.exists(sandbox.files.configFile))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: sandbox.files.configFile.deletingLastPathComponent().path)
      .sorted() == ["Snapshot", "notes.txt"])
  #expect(!sandbox.exists(sandbox.files.cacheDirectory))
  #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.files.snapshotDirectory.path).isEmpty)
  #expect(sandbox.exists(sandbox.unrelated))
}

@Test func resetCleansUpDiskSnapshotsAndSignsOutBeforeWiping() async throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let secrets = InMemorySecretStore([.accessToken: "tok", .masterKey: "key"])
  let api = FakeAccountAPI()
  await api.probeSecretsAtLogout { allSecrets(secrets) }
  let timeline = CallTimeline()
  let files = sandbox.files
  let reset = MacReset(
    files: files, secrets: secrets,
    cleanUpDiskSnapshots: {
      timeline.record(FileManager.default.fileExists(atPath: files.configFile.path) ? "cleanup" : "late cleanup")
    })
  let failed = await reset.run(signingOut: api, log: StructuredLog(summary: "Unlink this Mac", version: "1.2.3"))
  #expect(failed.isEmpty)
  #expect(timeline.entries == ["cleanup"])
  #expect(await api.calls == [.log("Unlink this Mac"), .logout])
  #expect(await api.secretsAtLogout == [.accessToken: "tok", .masterKey: "key"])
  #expect(allSecrets(secrets).isEmpty)
}

@Test func resetGivesUpOnAHangingSignOut() async throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let secrets = InMemorySecretStore([.accessToken: "tok"])
  let api = FakeAccountAPI()
  await api.script(logoutHangs: true)
  let reset = MacReset(
    files: sandbox.files, secrets: secrets, cleanUpDiskSnapshots: {}, signOutTimeout: .milliseconds(50))
  let failed = await reset.run(signingOut: api)
  #expect(failed.isEmpty)
  #expect(await api.calls == [.logout])
  #expect(allSecrets(secrets).isEmpty)
  #expect(!sandbox.exists(sandbox.files.configFile))
}

@Test func resetReportsWhatItCouldNotRemoveAndRemovesTheRest() async throws {
  let sandbox = try Sandbox()
  defer { sandbox.remove() }
  let reset = MacReset(files: sandbox.files, secrets: FailingSecretStore(), cleanUpDiskSnapshots: {})
  let failed = await reset.run()
  #expect(failed == [.secret(.masterKey)])
  #expect(!sandbox.exists(sandbox.files.configFile))
  #expect(!sandbox.exists(sandbox.files.cacheDirectory))
}

@Test func resetWithNothingStoredSucceeds() async throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent("mac-reset-\(UUID().uuidString)")
  let reset = MacReset(files: .standard(home: home), secrets: InMemorySecretStore(), cleanUpDiskSnapshots: {})
  #expect(await reset.run().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: home.path))
}
