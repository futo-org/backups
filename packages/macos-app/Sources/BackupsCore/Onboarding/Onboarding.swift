import Foundation

public enum OnboardingStep: Int, CaseIterable, Sendable {
  case fullDiskAccess
  case folders
  case ready

  public var title: String {
    switch self {
    case .fullDiskAccess: "Disk access"
    case .folders: "Folders"
    case .ready: "Ready"
    }
  }

  public static func steps(hasFullDiskAccess: Bool) -> [OnboardingStep] {
    hasFullDiskAccess ? [.folders, .ready] : allCases
  }
}

public struct OnboardingChoices: Equatable, Sendable {
  public var openAtLogin = true
  public var checkForUpdates = true

  public init() {}
}

extension AppConfig {
  public var needsOnboarding: Bool {
    onboardingCompletedAt == nil && folders.isEmpty
  }

  public mutating func treatExistingFoldersAsOnboarded(at date: Date) -> Bool {
    guard onboardingCompletedAt == nil, !folders.isEmpty else { return false }
    onboardingCompletedAt = date
    return true
  }

  public mutating func completeOnboarding(folders chosen: [String], at date: Date) {
    for path in chosen where !folders.contains(path) {
      folders.append(path)
    }
    if scheduleAnchor == nil {
      scheduleAnchor = date
    }
    onboardingCompletedAt = date
  }
}
