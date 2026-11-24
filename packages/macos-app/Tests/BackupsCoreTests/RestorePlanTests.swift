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

private func entry(_ path: String, _ kind: SnapshotEntry.Kind = .file) -> SnapshotEntry {
  SnapshotEntry(name: URL(fileURLWithPath: path).lastPathComponent, path: path, kind: kind)
}

@Test func batchesGroupPickedEntriesByTheirFolderInPickOrder() {
  let report = entry("/Users/x/Documents/report.pdf")
  let photos = entry("/Users/x/Pictures/Trip", .directory)
  let notes = entry("/Users/x/Documents/Work", .directory)
  let documents = entry("/Users/x/Documents", .directory)
  #expect(
    RestorePlan.batches(for: [report, photos, notes, documents], into: target) == [
      .children([report, notes], of: "/Users/x/Documents"),
      .children([photos], of: "/Users/x/Pictures"),
      .children([documents], of: "/Users/x"),
    ])
}

@Test func batchesRestoreTheWholeVolumeAsOneFolder() {
  let volume = SnapshotEntry(name: "Macintosh HD", path: "/", kind: .directory)
  let top = entry("/Users", .directory)
  #expect(
    RestorePlan.batches(for: [volume, top], into: target) == [
      .folder(RestoreItem(snapshotPath: "/", target: target.appendingPathComponent("Macintosh HD"))),
      .children([top], of: "/"),
    ])
}

@Test func batchesAreNamedAfterWhatTheyBringBack() {
  let item = RestoreItem(snapshotPath: "/Users/x/Documents", target: target.appendingPathComponent("Documents"))
  let volume = RestoreItem(snapshotPath: "/", target: target.appendingPathComponent("Macintosh HD"))
  let report = entry("/Users/x/Documents/report.pdf")
  let notes = entry("/Users/x/Documents/Work", .directory)
  #expect(RestoreBatch.folder(item).name == "Documents")
  #expect(RestoreBatch.folder(volume).name == "Macintosh HD")
  #expect(RestoreBatch.children([report], of: "/Users/x/Documents").name == "report.pdf")
  #expect(RestoreBatch.children([report, notes], of: "/Users/x/Documents").name == "Documents")
  #expect(RestoreBatch.children([report, notes], of: "/").name == "Macintosh HD")
}

@Test(arguments: [
  ("report.pdf", SnapshotEntry.Kind.file, ["report.pdf", "report 2.pdf", "report 3.pdf"]),
  ("archive.tar.gz", .file, ["archive.tar.gz", "archive.tar 2.gz", "archive.tar 3.gz"]),
  (".bashrc", .file, [".bashrc", ".bashrc 2", ".bashrc 3"]),
  ("Makefile", .file, ["Makefile", "Makefile 2", "Makefile 3"]),
  ("Project.app", .symlink, ["Project.app", "Project 2.app", "Project 3.app"]),
  ("My.Project", .directory, ["My.Project", "My.Project 2", "My.Project 3"]),
])
func claimNameNumbersLikeFinder(_ name: String, _ kind: SnapshotEntry.Kind, _ attempts: [String]) throws {
  var tried: [String] = []
  let picked = SnapshotEntry(name: name, path: "/d/" + name, kind: kind)
  let claimed = try RestorePlan.claimName(for: picked, in: target, avoiding: []) { url in
    tried.append(url.lastPathComponent)
    return tried.count == 3
  }
  #expect(tried == attempts)
  #expect(claimed == target.appendingPathComponent(attempts[2]))
}

@Test func claimNameSkipsNamesTakenByThisRestoreIgnoringCase() throws {
  var tried: [String] = []
  let claimed = try RestorePlan.claimName(
    for: entry("/d/Report.pdf"), in: target, avoiding: ["report.pdf"]
  ) { url in
    tried.append(url.lastPathComponent)
    return true
  }
  #expect(claimed == target.appendingPathComponent("Report 2.pdf"))
  #expect(tried == ["Report 2.pdf"])
}

@Test func claimNamePropagatesPlacementErrors() {
  #expect(throws: POSIXError(.EXDEV)) {
    _ = try RestorePlan.claimName(for: entry("/d/a.txt"), in: target, avoiding: []) { _ in
      throw POSIXError(.EXDEV)
    }
  }
}

@Test func claimStagingUsesTheFirstFreeHiddenFolder() throws {
  var tried: [String] = []
  let staging = try RestorePlan.claimStaging(in: target) { url in
    tried.append(url.lastPathComponent)
    return tried.count == 2
  }
  #expect(tried == [".FUTO Backups Restore", ".FUTO Backups Restore 2"])
  #expect(staging == target.appendingPathComponent(".FUTO Backups Restore 2"))
}

@Test func moveExclusivelyNeverReplacesAnExistingItem() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let source = root.appendingPathComponent("source.txt")
  let taken = root.appendingPathComponent("taken.txt")
  try Data("restored".utf8).write(to: source)
  try Data("mine".utf8).write(to: taken)
  #expect(try !RestorePlan.moveExclusively(from: source, to: taken))
  #expect(try Data(contentsOf: taken) == Data("mine".utf8))
  let free = root.appendingPathComponent("free.txt")
  #expect(try RestorePlan.moveExclusively(from: source, to: free))
  #expect(try Data(contentsOf: free) == Data("restored".utf8))
  #expect(!FileManager.default.fileExists(atPath: source.path))
  #expect(throws: POSIXError(.ENOENT)) {
    _ = try RestorePlan.moveExclusively(from: source, to: root.appendingPathComponent("other.txt"))
  }
}
