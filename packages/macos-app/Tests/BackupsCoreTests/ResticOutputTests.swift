import Foundation
import Testing

@testable import BackupsCore

@Test(
  arguments: [
    (
      #"{"message_type":"status","percent_done":0.5,"total_files":10,"files_done":5,"total_bytes":1000,"bytes_done":500,"seconds_remaining":7}"#,
      ResticMessage.status(
        BackupProgress(
          percentDone: 0.5, totalFiles: 10, filesDone: 5, totalBytes: 1000, bytesDone: 500, secondsRemaining: 7))
    ),
    (
      #"{"message_type":"status"}"#,
      ResticMessage.status(
        BackupProgress(
          percentDone: 0, totalFiles: 0, filesDone: 0, totalBytes: 0, bytesDone: 0, secondsRemaining: nil))
    ),
    (
      #"{"message_type":"summary","files_new":3,"files_changed":1,"files_unmodified":2,"data_added":4096,"total_files_processed":6,"total_bytes_processed":8192,"snapshot_id":"abc123"}"#,
      ResticMessage.summary(
        BackupSummary(
          filesNew: 3, filesChanged: 1, filesUnmodified: 2, dataAdded: 4096, totalFilesProcessed: 6,
          totalBytesProcessed: 8192, snapshotId: "abc123"))
    ),
    (
      #"{"message_type":"summary","files_new":1,"total_files_processed":1,"total_bytes_processed":3}"#,
      ResticMessage.summary(
        BackupSummary(
          filesNew: 1, filesChanged: 0, filesUnmodified: 0, dataAdded: 0, totalFilesProcessed: 1,
          totalBytesProcessed: 3, snapshotId: nil))
    ),
    (
      #"{"message_type":"error","error":{"message":"open: permission denied"},"during":"scan","item":"/p/secret"}"#,
      ResticMessage.error("/p/secret: open: permission denied")
    ),
    (
      #"{"message_type":"error","error":{"message":"open: permission denied"}}"#,
      ResticMessage.error("open: permission denied")
    ),
    (#"{"message_type":"initialized","id":"abc"}"#, ResticMessage.other),
    ("not json at all", ResticMessage.other),
    ("", ResticMessage.other),
  ] as [(line: String, expected: ResticMessage)])
func parseLineMatches(_ line: String, _ expected: ResticMessage) {
  #expect(ResticOutput.parseLine(line) == expected)
}

@Test func parseSnapshotsHandlesFractionsAndMissingFields() throws {
  let json = """
    [
      {"id":"aaaa","short_id":"aa","time":"2026-11-21T10:00:00.123456789+01:00","paths":["/src","/other"], \
    "hostname":"host-a","tags":["t1","t2"],"summary":{"total_files_processed":3,"total_bytes_processed":99,"data_added":50}},
      {"id":"bbbb","short_id":"bb","time":"2026-11-21T10:05:00Z","paths":["/src"],"hostname":"host-a"}
    ]
    """
  let snapshots = try ResticOutput.parseSnapshots(Data(json.utf8))
  #expect(snapshots.count == 2)
  let fractionalFormatter = ISO8601DateFormatter()
  fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let expectedFirst = try #require(fractionalFormatter.date(from: "2026-11-21T09:00:00.123Z"))
  #expect(snapshots[0].id == "aaaa")
  #expect(snapshots[0].shortId == "aa")
  #expect(snapshots[0].time == expectedFirst)
  #expect(snapshots[0].paths == ["/src", "/other"])
  #expect(snapshots[0].hostname == "host-a")
  #expect(snapshots[0].tags == ["t1", "t2"])
  #expect(snapshots[0].totalFilesProcessed == 3)
  #expect(snapshots[0].totalBytesProcessed == 99)
  #expect(snapshots[0].dataAdded == 50)
  let plainFormatter = ISO8601DateFormatter()
  plainFormatter.formatOptions = [.withInternetDateTime]
  let expectedSecond = try #require(plainFormatter.date(from: "2026-11-21T10:05:00Z"))
  #expect(snapshots[1].id == "bbbb")
  #expect(snapshots[1].time == expectedSecond)
  #expect(snapshots[1].tags == [])
  #expect(snapshots[1].totalFilesProcessed == nil)
  #expect(snapshots[1].totalBytesProcessed == nil)
  #expect(snapshots[1].dataAdded == nil)
}

@Test func parseSnapshotsRejectsBadInput() {
  #expect(throws: (any Error).self) {
    try ResticOutput.parseSnapshots(Data("not json".utf8))
  }
  #expect(throws: (any Error).self) {
    try ResticOutput.parseSnapshots(
      Data(#"[{"id":"a","short_id":"a","time":"nope","paths":[],"hostname":"h"}]"#.utf8))
  }
}

@Test func parseStatsAndVersion() throws {
  #expect(try ResticOutput.parseStatsTotalSize(Data(#"{"total_size": 12345,"total_file_size":1}"#.utf8)) == 12345)
  #expect(
    try ResticOutput.parseVersion(
      Data(#"{"version":"0.19.1+futo.1e904f0","executable":"/bin/restic"}"#.utf8)) == "0.19.1+futo.1e904f0")
  #expect(throws: (any Error).self) {
    try ResticOutput.parseStatsTotalSize(Data("{}".utf8))
  }
  #expect(throws: (any Error).self) {
    try ResticOutput.parseVersion(Data("[]".utf8))
  }
}

@Test(
  arguments: [
    (
      "exit_error wins over everything",
      """
      {"message_type":"error","error":{"message":"item failed"},"item":"/x"}
      {"message_type":"exit_error","code":3,"message":"Fatal: there are errors"}
      trailing plain text
      """,
      3,
      "Fatal: there are errors"
    ),
    (
      "last error message without exit_error",
      """
      plain noise
      {"message_type":"error","error":{"message":"first failure"},"item":"/a"}
      {"message_type":"error","error":{"message":"second failure"}}
      """,
      1,
      "second failure"
    ),
    (
      "error message composes item",
      #"{"message_type":"error","error":{"message":"cannot read"},"item":"/b/c"}"#,
      1,
      "/b/c: cannot read"
    ),
    (
      "last non-empty stderr line",
      "first line\n\nsecond line\n   ",
      1,
      "second line"
    ),
    ("empty stderr", "", 1, "restic exited with code 1"),
    ("whitespace stderr", "\n\n  \n", 7, "restic exited with code 7"),
  ] as [(name: String, stderr: String, exitCode: Int32, expected: String)])
func errorMessagePrecedence(_ name: String, _ stderr: String, _ exitCode: Int32, _ expected: String) {
  #expect(ResticOutput.errorMessage(stderr: stderr, exitCode: exitCode) == expected, "\(name)")
}

@Test(
  arguments: [
    (
      """
      {"message_type":"error","error":{"message":"first"},"during":"archival","item":"/a"}
        {"message_type":"error","error":{"message":"permission denied"},"during":"archival","item":"/b c/d"}
      {"message_type":"exit_error","code":3,"message":"Warning: at least one source file could not be read"}
      """,
      "/b c/d: permission denied"
    ),
    (#"{"message_type":"error","error":{"message":"no item"}}"#, "no item"),
    (#"{"message_type":"exit_error","code":3,"message":"Warning"}"#, nil),
    ("plain noise\n", nil),
    ("", nil),
  ] as [(stderr: String, expected: String?)])
func lastItemErrorReadsTheLastStderrErrorLine(_ stderr: String, _ expected: String?) {
  #expect(ResticOutput.lastItemError(stderr: stderr) == expected)
}
