import Foundation
import Testing

@testable import BackupsCore

private let progress = BackupProgress(percentDone: 0.42, totalBytes: 100, bytesDone: 42)
private let speed = UploadSpeed(uploadedBytes: 42, bytesPerSecond: 10)

@Test(arguments: [
  (EngineActivity.preparing, ActivityPhase.preparing),
  (.backingUp(progress, speed), .backingUp),
  (.finishing(.removingDiskSnapshot), .finishing(.removingDiskSnapshot)),
  (.finishing(.checkingCloudOnlyFiles), .finishing(.checkingCloudOnlyFiles)),
  (.pruning, .pruning),
  (.restoring, .restoring),
  (.changingRecoveryKey, .changingRecoveryKey),
])
func phaseDropsTheProgressPayload(activity: EngineActivity, phase: ActivityPhase) {
  #expect(activity.phase == phase)
}

@Test func backingUpPhaseIgnoresProgressChanges() {
  var later = progress
  later.bytesDone = 99
  #expect(EngineActivity.backingUp(progress, speed).phase == EngineActivity.backingUp(later, UploadSpeed()).phase)
}

@Test func onlyBackingUpCarriesASample() {
  #expect(EngineActivity.backingUp(progress, speed).backupSample == BackupSample(progress: progress, speed: speed))
  #expect(EngineActivity.preparing.backupSample == nil)
  #expect(EngineActivity.finishing(.removingDiskSnapshot).backupSample == nil)
  #expect(EngineActivity.restoring.backupSample == nil)
}

@Test(arguments: [
  (0.0, 0.0), (0.004, 0.0), (0.005, 0.01), (0.125, 0.13), (0.4249, 0.42), (0.999, 1.0), (1.0, 1.0),
])
func wholePercentFractionRoundsToWholePercents(percentDone: Double, expected: Double) {
  #expect(BackupProgress(percentDone: percentDone).wholePercentFraction == expected)
}

@Test(arguments: [(0.125, "13%"), (0.135, "14%"), (0.285, "28%"), (0.999, "100%")])
func wholePercentFractionsFormatWithoutRoundingAgain(percentDone: Double, label: String) {
  let format = FloatingPointFormatStyle<Double>.Percent(locale: Locale(identifier: "en_US"))
    .precision(.fractionLength(0))
  #expect(percentDone.wholePercentFraction.formatted(format) == label)
}
