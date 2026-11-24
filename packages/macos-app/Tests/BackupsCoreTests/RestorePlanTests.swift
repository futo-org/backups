import Darwin
import Foundation
import Testing

@testable import BackupsCore

private let target = URL(fileURLWithPath: "/Volumes/Restore")

@Test func eachFolderRestoresUnderItsOwnName() {
  let items = RestorePlan.items(
    paths: ["/Users/x/Documents", "/Users/x/Pictures"], into: target, exists: { _ in false })
  #expect(
    items == [
      RestoreItem(snapshotPath: "/Users/x/Documents", target: target.appendingPathComponent("Documents")),
      RestoreItem(snapshotPath: "/Users/x/Pictures", target: target.appendingPathComponent("Pictures")),
    ])
}

@Test func sameNamedFoldersGetNumberedIgnoringCase() {
  let items = RestorePlan.items(
    paths: ["/Users/x/Documents", "/Volumes/Work/documents", "/Volumes/Old/Documents"], into: target,
    exists: { _ in false })
  #expect(items.map(\.target.lastPathComponent) == ["Documents", "documents 2", "Documents 3"])
}

@Test func existingItemsInTheTargetAreNeverReused() {
  let existing: Set<String> = ["Documents", "Documents 2"]
  let items = RestorePlan.items(
    paths: ["/Users/x/Documents"], into: target, exists: { existing.contains($0.lastPathComponent) })
  #expect(items.map(\.target.lastPathComponent) == ["Documents 3"])
}

@Test func wholeVolumeRestoresUnderTheVolumeName() {
  let items = RestorePlan.items(paths: ["/"], into: target, exists: { _ in false })
  #expect(items == [RestoreItem(snapshotPath: "/", target: target.appendingPathComponent("Macintosh HD"))])
}

@Test func claimTargetKeepsThePlannedNameWhenItIsFree() throws {
  var attempts: [String] = []
  let item = RestoreItem(snapshotPath: "/Users/x/Documents", target: target.appendingPathComponent("Documents 2"))
  let claimed = try RestorePlan.claimTarget(for: item, avoiding: []) { url in
    attempts.append(url.lastPathComponent)
    return true
  }
  #expect(claimed == target.appendingPathComponent("Documents 2"))
  #expect(attempts == ["Documents 2"])
}

@Test func claimTargetMovesPastTakenAndExistingNames() throws {
  var attempts: [String] = []
  let existing: Set<String> = ["Documents", "Documents 3"]
  let item = RestoreItem(snapshotPath: "/Users/x/Documents", target: target.appendingPathComponent("Documents"))
  let claimed = try RestorePlan.claimTarget(for: item, avoiding: ["documents 2"]) { url in
    attempts.append(url.lastPathComponent)
    return !existing.contains(url.lastPathComponent)
  }
  #expect(claimed == target.appendingPathComponent("Documents 4"))
  #expect(attempts == ["Documents", "Documents 3", "Documents 4"])
}

@Test func claimTargetNumbersTheWholeVolumeName() throws {
  let item = RestoreItem(snapshotPath: "/", target: target.appendingPathComponent("Macintosh HD"))
  let claimed = try RestorePlan.claimTarget(for: item, avoiding: []) { url in
    url.lastPathComponent != "Macintosh HD"
  }
  #expect(claimed == target.appendingPathComponent("Macintosh HD 2"))
}

@Test func claimTargetPropagatesCreationErrors() {
  let item = RestoreItem(snapshotPath: "/Users/x/Documents", target: target.appendingPathComponent("Documents"))
  #expect(throws: POSIXError(.EACCES)) {
    _ = try RestorePlan.claimTarget(for: item, avoiding: []) { _ in throw POSIXError(.EACCES) }
  }
}

@Test func createDirectoryExclusivelyFailsWhenTheDirectoryExists() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let directory = root.appendingPathComponent("Documents")
  #expect(try RestorePlan.createDirectoryExclusively(directory))
  #expect(try !RestorePlan.createDirectoryExclusively(directory))
  try Data("x".utf8).write(to: root.appendingPathComponent("file"))
  #expect(try !RestorePlan.createDirectoryExclusively(root.appendingPathComponent("file")))
  #expect(throws: POSIXError(.ENOENT)) {
    _ = try RestorePlan.createDirectoryExclusively(root.appendingPathComponent("missing/child"))
  }
}
