import BackupsCore
import Foundation
import Testing

@Test func fullDiskAccessStepIsSkippedWhenAlreadyGranted() {
  #expect(OnboardingStep.steps(hasFullDiskAccess: false) == [.fullDiskAccess, .folders, .ready])
  #expect(OnboardingStep.steps(hasFullDiskAccess: true) == [.folders, .ready])
}

@Test func stepsHaveTitles() {
  #expect(OnboardingStep.allCases.map(\.title) == ["Disk access", "Folders", "Ready"])
}

@Test func freshConfigNeedsOnboarding() {
  #expect(AppConfig.defaults(host: "Mac", home: "/Users/test").needsOnboarding)
}

@Test func configWithFoldersDoesNotNeedOnboarding() {
  var config = AppConfig.defaults(host: "Mac", home: "/Users/test")
  config.folders = ["/Users/test/Documents"]
  #expect(!config.needsOnboarding)
}

@Test func completedOnboardingIsNotShownAgainEvenWithoutFolders() {
  var config = AppConfig.defaults(host: "Mac", home: "/Users/test")
  config.onboardingCompletedAt = Date(timeIntervalSince1970: 1_781_092_800)
  #expect(!config.needsOnboarding)
}

@Test func existingFoldersAreTreatedAsOnboardedOnce() {
  let date = Date(timeIntervalSince1970: 1_781_092_800)
  var config = AppConfig.defaults(host: "Mac", home: "/Users/test")
  let withoutFolders = config.treatExistingFoldersAsOnboarded(at: date)
  #expect(!withoutFolders)
  #expect(config.onboardingCompletedAt == nil)
  config.folders = ["/Users/test/Documents"]
  let withFolders = config.treatExistingFoldersAsOnboarded(at: date)
  #expect(withFolders)
  #expect(config.onboardingCompletedAt == date)
  let again = config.treatExistingFoldersAsOnboarded(at: date.addingTimeInterval(60))
  #expect(!again)
  #expect(config.onboardingCompletedAt == date)
}

@Test func completingOnboardingSavesFoldersAndAnchorsTheSchedule() {
  let date = Date(timeIntervalSince1970: 1_781_092_800)
  var config = AppConfig.defaults(host: "Mac", home: "/Users/test")
  config.completeOnboarding(folders: ["/Users/test/Documents", "/Users/test/Desktop"], at: date)
  #expect(config.folders == ["/Users/test/Documents", "/Users/test/Desktop"])
  #expect(config.onboardingCompletedAt == date)
  #expect(config.scheduleAnchor == date)
  #expect(!config.needsOnboarding)
}

@Test func completingOnboardingKeepsExistingFoldersAndAnchor() {
  let anchor = Date(timeIntervalSince1970: 1_700_000_000)
  let date = Date(timeIntervalSince1970: 1_781_092_800)
  var config = AppConfig.defaults(host: "Mac", home: "/Users/test")
  config.folders = ["/Users/test/Documents"]
  config.scheduleAnchor = anchor
  config.completeOnboarding(folders: ["/Users/test/Pictures", "/Users/test/Documents"], at: date)
  #expect(config.folders == ["/Users/test/Documents", "/Users/test/Pictures"])
  #expect(config.scheduleAnchor == anchor)
}
