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
