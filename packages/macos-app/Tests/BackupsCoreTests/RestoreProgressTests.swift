import Testing

@testable import BackupsCore

@Test(arguments: [
  (
    #"{"message_type":"status","percent_done":0.4558744579047078,"total_files":42,"files_restored":16,"total_bytes":80000003,"bytes_restored":36469958}"#,
    RestoreMessage.status(
      RestoreProgress(
        percentDone: 0.4558744579047078, totalFiles: 42, filesRestored: 16, totalBytes: 80_000_003,
        bytesRestored: 36_469_958))
  ),
  (
    #"{"message_type":"status","seconds_elapsed":2,"percent_done":0.4153553529411765,"total_files":77,"files_restored":35,"files_skipped":21,"total_bytes":170000000,"bytes_restored":70610410,"bytes_skipped":30000003}"#,
    .status(
      RestoreProgress(
        percentDone: 0.4153553529411765, totalFiles: 77, filesRestored: 35, totalBytes: 170_000_000,
        bytesRestored: 70_610_410))
  ),
  (
    #"{"message_type":"status","percent_done":0,"total_files":6735,"total_bytes":80499}"#,
    .status(RestoreProgress(totalFiles: 6735, totalBytes: 80499))
  ),
  (
    #"{"message_type":"status","percent_done":0,"total_files":40043,"files_restored":891}"#,
    .status(RestoreProgress(totalFiles: 40043, filesRestored: 891))
  ),
  (
    #"{"message_type":"summary","seconds_elapsed":2,"total_files":42,"files_restored":42,"total_bytes":80000003,"bytes_restored":80000003}"#,
    .summary(
      RestoreProgress(
        percentDone: 1, totalFiles: 42, filesRestored: 42, totalBytes: 80_000_003, bytesRestored: 80_000_003))
  ),
  (
    #"{"message_type":"summary","total_files":2,"files_restored":2,"files_skipped":61,"bytes_skipped":110000003}"#,
    .summary(RestoreProgress(percentDone: 1, totalFiles: 2, filesRestored: 2))
  ),
])
func parsesResticRestoreStatusAndSummaryLines(line: String, expected: RestoreMessage) {
  #expect(RestoreMessage.parse(line) == expected)
}

@Test(arguments: [
  #"{"message_type":"exit_error","code":1,"message":"path nope: not found"}"#,
  #"{"message_type":"error","error":{"message":"denied"},"during":"restore","item":"/a"}"#,
  #"{"message_type":"verbose_status","action":"restored","item":"/a","size":3}"#,
  #"{"message_type":"status","percent_done":"#,
  "restoring <Snapshot abc of [/src]> to /target",
  "",
])
func ignoresLinesThatCarryNoRestoreProgress(line: String) {
  #expect(RestoreMessage.parse(line) == nil)
}

@Test func countsAsStartedOnceRestoringWritesSomething() {
  #expect(!RestoreProgress(totalFiles: 10_050, totalBytes: 119_302).hasStarted)
  #expect(RestoreProgress(totalFiles: 3, filesRestored: 1).hasStarted)
  #expect(RestoreProgress(totalBytes: 10, bytesRestored: 1).hasStarted)
}

@Test(arguments: [
  (RestoreProgress(percentDone: 0.35, totalFiles: 4, filesRestored: 3, totalBytes: 100, bytesRestored: 35), 0.35),
  (RestoreProgress(totalFiles: 4, filesRestored: 1), 0.25),
  (RestoreProgress(totalFiles: 4, filesRestored: 5), 1.0),
  (RestoreProgress(), 0.0),
])
func countsItemsTowardsTheFractionOnlyWhenThereAreNoBytes(progress: RestoreProgress, expected: Double) {
  #expect(progress.fractionDone == expected)
}
