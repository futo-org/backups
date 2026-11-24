import Foundation
import Testing

@testable import BackupsCore

private let mount = "/Users/test/Library/Application Support/FUTO Backups/Snapshot/Volume"

private func errorLine(item: String, message: String, during: String = "archival") -> String {
  let payload: [String: Any] = [
    "message_type": "error", "error": ["message": message], "during": during, "item": item,
  ]
  let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
  return String(decoding: data, as: UTF8.self)
}

@Test func collectsPermissionDeniedErrorsAmongStatusAndSummaryLines() {
  let stderr = [
    #"{"message_type":"status","percent_done":0.5,"total_files":10,"files_done":5}"#,
    errorLine(
      item: "/Users/test/Documents/locked.txt",
      message: "open /Users/test/Documents/locked.txt: permission denied"),
    "unexpected plain text from restic",
    #"{"message_type":"summary","files_new":3,"snapshot_id":"abc"}"#,
    errorLine(
      item: "/Users/test/Documents/Mail",
      message: "openfile for readdirnames failed: open /Users/test/Documents/Mail: operation not permitted"),
    #"{"message_type":"exit_error","code":3,"message":"Warning: at least one source file could not be read"}"#,
  ].joined(separator: "\n")

  let warnings = BackupWarnings.collect(stderr: stderr)

  #expect(
    warnings.items == [
      BackupWarning(path: "/Users/test/Documents/locked.txt", reason: "Permission denied"),
      BackupWarning(path: "/Users/test/Documents/Mail", reason: "Operation not permitted"),
    ])
  #expect(warnings.total == 2)
  #expect(!warnings.isTruncated)
}

@Test func mapsSnapshotPathsToLivePathsAndDeduplicatesAcrossSpellings() {
  let stderr = [
    errorLine(
      item: mount + "/Users/test/Docs/sub",
      message: "openfile for readdirnames failed: open \(mount)/Users/test/Docs/sub: permission denied",
      during: "scan"),
    errorLine(
      item: mount + "/Users/test/Docs/locked.txt",
      message: "\(mount)/Users/test/Docs/locked.txt: open Users/test/Docs/locked.txt: permission denied"),
    errorLine(
      item: "Users/test/Docs/sub",
      message: "openfile for readdirnames failed: open Users/test/Docs/sub: permission denied"),
    errorLine(item: "/Volumes/External/photo.jpg", message: "read /Volumes/External/photo.jpg: input/output error"),
  ].joined(separator: "\n")

  let warnings = BackupWarnings.collect(stderr: stderr, snapshotMounts: [mount])

  #expect(
    warnings.items == [
      BackupWarning(path: "/Users/test/Docs/sub", reason: "Permission denied"),
      BackupWarning(path: "/Users/test/Docs/locked.txt", reason: "Permission denied"),
      BackupWarning(path: "/Volumes/External/photo.jpg", reason: "Input/output error"),
    ])
  #expect(warnings.total == 3)
}

@Test func mapsEitherSpellingOfTheSnapshotMount() {
  let resolved = "/private/var/folders/x/Snapshot/Volume"
  let stderr = [
    errorLine(item: resolved + "/Users/test/a.txt", message: "permission denied"),
    errorLine(item: "/var/folders/x/Snapshot/Volume/Users/test/b.txt", message: "permission denied"),
    errorLine(item: resolved, message: "permission denied"),
  ].joined(separator: "\n")

  let warnings = BackupWarnings.collect(
    stderr: stderr, snapshotMounts: [resolved, "/var/folders/x/Snapshot/Volume"])

  #expect(warnings.items.map(\.path) == ["/Users/test/a.txt", "/Users/test/b.txt", "/"])
}

@Test func keepsReasonsThatDoNotRepeatThePath() {
  let stderr = [
    errorLine(item: "/Users/test/Documents/report.docx", message: "file changed during backup"),
    errorLine(
      item: "/Users/test/Documents/gone.txt",
      message: "lstat /Users/test/Documents/gone.txt: no such file or directory"),
    errorLine(item: "/Users/test/Documents/odd.txt", message: "/Users/test/Documents/odd.txt: "),
  ].joined(separator: "\n")

  let warnings = BackupWarnings.collect(stderr: stderr)

  #expect(
    warnings.items.map(\.reason) == [
      "File changed during backup", "No such file or directory", "/Users/test/Documents/odd.txt:",
    ])
}

@Test func ignoresErrorsWithoutAnItemOrMessage() {
  let stderr = [
    #"{"message_type":"error","error":{"message":"repository busy"}}"#,
    #"{"message_type":"error","error":{},"item":"/a"}"#,
    #"{"message_type":"error","error":{"message":"permission denied"},"item":""}"#,
    #"{"message_type":"verbose_status","action":"new","item":"/b"}"#,
    "{not json",
  ].joined(separator: "\n")

  #expect(BackupWarnings.collect(stderr: stderr) == BackupWarnings())
  #expect(BackupWarnings.collect(stderr: "") == BackupWarnings())
}

@Test func deduplicatesRepeatedPathsKeepingTheFirstReason() {
  let stderr = [
    errorLine(item: "/a/b", message: "open /a/b: permission denied"),
    errorLine(item: "/a/b", message: "read /a/b: resource busy"),
  ].joined(separator: "\r\n")

  let warnings = BackupWarnings.collect(stderr: stderr)

  #expect(warnings.items == [BackupWarning(path: "/a/b", reason: "Permission denied")])
  #expect(warnings.total == 1)
}

@Test func keepsTheFirstFiveHundredAndCountsTheRest() {
  let stderr = (0..<1_234).map { index in
    errorLine(item: "/Users/test/f\(index)", message: "open /Users/test/f\(index): permission denied")
  }
  .joined(separator: "\n")

  let warnings = BackupWarnings.collect(stderr: stderr + "\n" + stderr)

  #expect(warnings.items.count == BackupWarnings.itemLimit)
  #expect(warnings.items.first?.path == "/Users/test/f0")
  #expect(warnings.items.last?.path == "/Users/test/f499")
  #expect(warnings.total == 1_234)
  #expect(warnings.isTruncated)
}

@Test(arguments: [
  ("Users/test/a.txt", [mount], "/Users/test/a.txt"),
  (".", [mount], "/"),
  (mount, [mount], "/"),
  (mount + "/x", [mount], "/x"),
  (mount + "-other/x", [mount], mount + "-other/x"),
  ("/Users/test/a.txt", [], "/Users/test/a.txt"),
])
func livePathOfItem(item: String, mounts: [String], expected: String) {
  #expect(BackupWarnings.livePath(of: item, snapshotMounts: mounts) == expected)
}

@Test func listTextHasOneLinePerItemWithTheDisplayedPath() {
  let warnings = BackupWarnings(
    items: [
      BackupWarning(path: "/Users/test/a.txt", reason: "Permission denied"),
      BackupWarning(path: "/Volumes/X/b.txt", reason: "Resource busy"),
    ],
    total: 7)

  #expect(
    warnings.listText { $0.replacingOccurrences(of: "/Users/test", with: "~") }
      == "~/a.txt: Permission denied\n/Volumes/X/b.txt: Resource busy")
  #expect(warnings.listText().hasPrefix("/Users/test/a.txt: "))
}

@Test func warningsBelongOnlyToTheSnapshotTheRunCreated() {
  let warnings = BackupWarnings(items: [BackupWarning(path: "/a", reason: "Permission denied")], total: 1)
  let record = RunRecord(
    startedAt: Date(timeIntervalSince1970: 0), finishedAt: Date(timeIntervalSince1970: 5), status: .warn,
    snapshotId: "abc", warnings: warnings)

  #expect(record.warnings(forSnapshot: "abc") == warnings)
  #expect(record.warnings(forSnapshot: "def") == nil)
}
