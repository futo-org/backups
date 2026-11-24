import BackupsCore
import Foundation
import Testing

private func temporaryRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

@Test("missing file loads defaults")
func missingFileLoadsDefaults() throws {
  let root = temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigStore(fileURL: root.appendingPathComponent("FUTO Backups").appendingPathComponent("config.json"))
  let config = try store.load(defaultHost: "host-a", home: "/Users/test")
  #expect(config == AppConfig.defaults(host: "host-a", home: "/Users/test"))
}

@Test("save creates nested directories and load round trips")
func saveThenLoadRoundTrip() throws {
  let root = temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigStore(fileURL: root.appendingPathComponent("FUTO Backups").appendingPathComponent("config.json"))
  var config = AppConfig.defaults(host: "host-b", home: "/Users/test")
  config.serverURL = AppConfig.devServerURL
  config.folders = ["/Users/test/Documents"]
  config.repositoryId = "0b6a1f6e-3c1d-4c2a-9f7e-5d4b3a2c1e0f"
  config.lastRun = RunRecord(
    startedAt: Date(timeIntervalSince1970: 1_781_092_800),
    finishedAt: Date(timeIntervalSince1970: 1_781_093_100),
    status: .complete,
    snapshotId: "deadbeef",
    filesNew: 7,
    dataAdded: 4242
  )
  try store.save(config)
  #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
  let loaded = try store.load(defaultHost: "ignored-host", home: "/ignored")
  #expect(loaded == config)
  #expect(loaded.host == "host-b")
}

@Test("save writes pretty-printed sorted ISO 8601 JSON")
func saveFormat() throws {
  let root = temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
  var config = AppConfig.defaults(host: "host-c", home: "/Users/test")
  config.lastRun = RunRecord(
    startedAt: Date(timeIntervalSince1970: 1_781_092_800),
    finishedAt: Date(timeIntervalSince1970: 1_781_092_860),
    status: .complete
  )
  try store.save(config)
  let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
  #expect(raw.contains("\n  \"excludes\" : ["))
  #expect(raw.contains("\"startedAt\" : \"2026-06-10T12:00:00Z\""))
}

@Test("corrupt file throws instead of resetting")
func corruptFileThrows() throws {
  let root = temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try Data("not json".utf8).write(to: store.fileURL)
  #expect(throws: (any Error).self) {
    _ = try store.load(defaultHost: "host-d", home: "/Users/test")
  }
}

@Test("moveAside renames the file with an ISO 8601 stamp and keeps its contents")
func moveAsideKeepsCorruptFile() throws {
  let root = temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try Data("not json".utf8).write(to: store.fileURL)
  let moved = try #require(try store.moveAside(at: Date(timeIntervalSince1970: 1_781_092_800)))
  #expect(moved == root.appendingPathComponent("config.json.corrupt-2026-06-10T120000Z"))
  #expect(try Data(contentsOf: moved) == Data("not json".utf8))
  #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
  try store.save(AppConfig.defaults(host: "host-e", home: "/Users/test"))
  #expect(try Data(contentsOf: moved) == Data("not json".utf8))
  #expect(try store.load(defaultHost: "ignored", home: "/ignored").host == "host-e")
}

@Test("moveAside without a file does nothing")
func moveAsideWithoutFile() throws {
  let root = temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ConfigStore(fileURL: root.appendingPathComponent("config.json"))
  #expect(try store.moveAside(at: Date(timeIntervalSince1970: 1_781_092_800)) == nil)
}
