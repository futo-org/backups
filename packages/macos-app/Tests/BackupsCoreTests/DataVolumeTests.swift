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

@Test func relativePathOfTempDirectoryIsDataVolumeRelative() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let realPath = try #require(
    realpath(directory.path, nil).map { pointer in
      let value = String(cString: pointer)
      free(pointer)
      return value
    })
  let relative = try #require(DataVolume.relativePath(of: directory.path))
  #expect(relative == String(realPath.dropFirst()))
  #expect(relative.hasPrefix("private/") || relative.hasPrefix("var/"))
}

@Test func relativePathOfRootAndMissingPathIsNil() {
  #expect(DataVolume.relativePath(of: "/") == nil)
  #expect(DataVolume.relativePath(of: "/nonexistent-\(UUID().uuidString)") == nil)
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
