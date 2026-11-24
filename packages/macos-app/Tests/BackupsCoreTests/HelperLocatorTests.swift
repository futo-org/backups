import Foundation
import Testing

@testable import BackupsCore

private func makeTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func makeFile(at url: URL, executable: Bool) throws {
  try Data("x".utf8).write(to: url)
  if executable {
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
}

@Test func environmentExecutableWins() throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let helper = directory.appendingPathComponent("restic")
  try makeFile(at: helper, executable: true)
  let found = HelperLocator.locate(.restic, bundleURL: directory, environment: ["FUTO_BACKUPS_RESTIC": helper.path])
  #expect(found?.path == helper.path)
}

@Test func environmentNonExecutableFallsThroughToBundle() throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let decoy = directory.appendingPathComponent("decoy-restic")
  try makeFile(at: decoy, executable: false)
  let helpers = directory.appendingPathComponent("X.app").appendingPathComponent("Contents")
    .appendingPathComponent("Helpers")
  try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
  let bundled = helpers.appendingPathComponent("restic")
  try makeFile(at: bundled, executable: true)
  let found = HelperLocator.locate(
    .restic,
    bundleURL: directory.appendingPathComponent("X.app"),
    environment: ["FUTO_BACKUPS_RESTIC": decoy.path])
  #expect(found?.path == bundled.path)
}

@Test func bundleHelperFound() throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let helpers = directory.appendingPathComponent("X.app").appendingPathComponent("Contents")
    .appendingPathComponent("Helpers")
  try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
  let bundled = helpers.appendingPathComponent(Helper.resticProxy.rawValue)
  try makeFile(at: bundled, executable: true)
  let found = HelperLocator.locate(.resticProxy, bundleURL: directory.appendingPathComponent("X.app"), environment: [:])
  #expect(found?.path == bundled.path)
}

@Test func nothingFoundReturnsNil() throws {
  let directory = try makeTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(HelperLocator.locate(.restic, bundleURL: directory, environment: [:]) == nil)
}

@Test func environmentKeys() {
  #expect(Helper.restic.environmentKey == "FUTO_BACKUPS_RESTIC")
  #expect(Helper.resticProxy.environmentKey == "FUTO_BACKUPS_RESTIC_PROXY")
}
