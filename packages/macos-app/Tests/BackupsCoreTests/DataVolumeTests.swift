import Darwin
import Foundation
import Testing

@testable import BackupsCore

@Test(
  "data volume relative path",
  arguments: [
    ("/Users/a/Docs", DataVolume.mountPath, Optional("Users/a/Docs")),
    ("/System/Volumes/Data/Users/a", DataVolume.mountPath, Optional("Users/a")),
    (DataVolume.mountPath, DataVolume.mountPath, Optional(".")),
    ("/", DataVolume.mountPath, Optional<String>.none),
    ("relative/x", DataVolume.mountPath, Optional<String>.none),
    ("/Volumes/Ext/x", "/Volumes/Ext", Optional<String>.none),
    ("/Users/a", "/", Optional<String>.none),
  ])
func relativePath(realPath: String, volumeMountPath: String, expected: String?) {
  #expect(DataVolume.relativePath(realPath: realPath, volumeMountPath: volumeMountPath) == expected)
}

@Test func relativePathOfRealHomeDirectoryIsDataVolumeRelative() throws {
  let directory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("futo-backups-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let relative = try #require(DataVolume.relativePath(of: directory.path))
  #expect(relative == String(directory.path.dropFirst()))
  #expect(relative.hasPrefix("Users/"))
}

@Test func relativePathOfRootAndMissingPathIsNil() {
  #expect(DataVolume.relativePath(of: "/") == nil)
  #expect(DataVolume.relativePath(of: "/nonexistent-\(UUID().uuidString)") == nil)
}

@Test func relativePathOfSymlinkIsNilAndOfRealSubdirectoryIsNotNil() throws {
  let base = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("futo-backups-tests-\(UUID().uuidString)")
  let target = base.appendingPathComponent("real")
  let link = base.appendingPathComponent("link")
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  #expect(DataVolume.relativePath(of: link.path) == nil)
  #expect(DataVolume.relativePath(of: target.path) != nil)
  #expect(DataVolume.relativePath(of: target.path + "/") != nil)
}

@Test func relativePathThroughTmpSymlinkIsNil() throws {
  let name = UUID().uuidString
  let realDirectory = "/private/tmp/" + name
  try FileManager.default.createDirectory(atPath: realDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(atPath: realDirectory) }
  #expect(DataVolume.relativePath(of: "/tmp/" + name) == nil)
}

@Test func resolvedPathResolvesSymlinkedDirectory() throws {
  let base = URL(fileURLWithPath: DataVolume.resolvedPath(FileManager.default.temporaryDirectory.path))
    .appendingPathComponent(UUID().uuidString)
  let target = base.appendingPathComponent("real")
  let link = base.appendingPathComponent("link")
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: base) }
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  #expect(DataVolume.resolvedPath(link.path) == target.path)
}

@Test func resolvedPathReturnsInputForMissingPath() {
  let path = "/nonexistent-\(UUID().uuidString)"
  #expect(DataVolume.resolvedPath(path) == path)
}

@Test(
  "snapshot relative path",
  arguments: [
    ("/Users/a/Library/Caches", Optional("Users/a/Library/Caches")),
    ("/System/Volumes/Data/Users/a", Optional("Users/a")),
    ("/System/Volumes/Data", Optional(".")),
    ("/", Optional<String>.none),
    ("**/node_modules", Optional<String>.none),
    ("/Users/a/Library/Containers/*/Data/Library/Caches", Optional("Users/a/Library/Containers/*/Data/Library/Caches")),
  ])
func snapshotRelativePath(absolutePath: String, expected: String?) {
  #expect(DataVolume.snapshotRelativePath(absolutePath) == expected)
}

@Test func fullDiskAccessProbePointsAtTCCDatabase() {
  #expect(FullDiskAccess.probe.path == "/Library/Application Support/com.apple.TCC/TCC.db")
}

@Test func isGrantedIsTrueForReadableFile() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data("probe".utf8).write(to: file)
  defer { try? FileManager.default.removeItem(at: file) }
  #expect(FullDiskAccess.isGranted(probe: file))
}

@Test func isGrantedIsFalseForMissingFile() {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  #expect(!FullDiskAccess.isGranted(probe: file))
}

@Test func isGrantedIsFalseForUnreadableFile() throws {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data("probe".utf8).write(to: file)
  chmod(file.path, 0)
  defer {
    chmod(file.path, 0o600)
    try? FileManager.default.removeItem(at: file)
  }
  #expect(!FullDiskAccess.isGranted(probe: file))
}
