import Testing

@testable import BackupsCore

@Test(
  "isCancellable table",
  arguments: [
    (EngineActivity.preparing, true),
    (.finishing(.removingDiskSnapshot), true),
    (.pruning, true),
    (.restoring(RestoreStep(part: 1, partCount: 1, name: "Documents")), true),
    (.changingRecoveryKey, false),
  ])
func isCancellable(activity: EngineActivity, expected: Bool) {
  #expect(activity.isCancellable == expected)
}
