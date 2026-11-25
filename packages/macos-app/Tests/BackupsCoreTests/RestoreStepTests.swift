import Foundation
import Testing

@testable import BackupsCore

private let english = Locale(identifier: "en_US")
private let started = RestoreProgress(
  percentDone: 0.35, totalFiles: 4000, filesRestored: 1200, totalBytes: 3_400, bytesRestored: 1_200)
private let counting = RestoreProgress(totalFiles: 6735, totalBytes: 80499)

private func subtitle(_ step: RestoreStep) -> String {
  step.subtitle(locale: english) { "\($0) B" }
}

@Test func singlePartShowsItsOwnProgressAsTheOverallProgress() {
  let step = RestoreStep(part: 1, partCount: 1, name: "Documents", progress: started)
  #expect(step.title == "Restoring")
  #expect(subtitle(step) == "1200 B of 3400 B · 1,200 of 4,000 items")
  #expect(step.fraction == 0.35)
  #expect(step.overallFraction == 0.35)
}

@Test func multiplePartsNameThePartAndKeepTheOverallProgressUnknown() {
  let step = RestoreStep(part: 2, partCount: 3, name: "Pictures", progress: started)
  #expect(step.title == "Restoring 2 of 3")
  #expect(subtitle(step) == "Pictures · 1200 B of 3400 B · 1,200 of 4,000 items")
  #expect(step.fraction == 0.35)
  #expect(step.overallFraction == nil)
}

@Test(arguments: [nil, counting])
func nothingWrittenYetShowsNoPercent(progress: RestoreProgress?) {
  let single = RestoreStep(part: 1, partCount: 1, name: "Documents", progress: progress)
  #expect(single.fraction == nil)
  #expect(single.overallFraction == nil)
  #expect(subtitle(single) == "Bringing your files back")
  let multiple = RestoreStep(part: 1, partCount: 2, name: "Documents", progress: progress)
  #expect(subtitle(multiple) == "Documents · Bringing your files back")
}

@Test func aSingleItemIsNotPluralised() {
  let step = RestoreStep(
    part: 1, partCount: 1, name: "report.pdf",
    progress: RestoreProgress(percentDone: 1, totalFiles: 1, filesRestored: 1, totalBytes: 5, bytesRestored: 5))
  #expect(subtitle(step) == "5 B of 5 B · 1 of 1 item")
}

@Test func emptyFilesProgressByItemsWithoutAByteCounter() {
  let step = RestoreStep(
    part: 1, partCount: 1, name: "Notes", progress: RestoreProgress(totalFiles: 4, filesRestored: 1))
  #expect(step.fraction == 0.25)
  #expect(step.overallFraction == 0.25)
  #expect(subtitle(step) == "1 of 4 items")
}

@Test func theCompactSubtitleLeavesThePartNameToTheTitle() {
  let step = RestoreStep(part: 2, partCount: 3, name: String(repeating: "long name\n", count: 20), progress: started)
  #expect(step.subtitle(namingPart: false, locale: english) { "\($0) B" } == "1200 B of 3400 B · 1,200 of 4,000 items")
  let waiting = RestoreStep(part: 2, partCount: 3, name: "Pictures")
  #expect(waiting.subtitle(namingPart: false, locale: english) { "\($0) B" } == "Bringing your files back")
}
