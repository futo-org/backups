import Foundation

public struct BackgroundUpdateCheckGate: Equatable, Sendable {
  private var onboarding: Bool
  private var awaitingOptIn = false

  public init(onboarding: Bool) {
    self.onboarding = onboarding
  }

  public var allowsBackgroundChecks: Bool { !onboarding && !awaitingOptIn }

  public mutating func finishOnboarding(automaticChecks: Bool) {
    onboarding = false
    awaitingOptIn = !automaticChecks
  }

  public mutating func automaticChecksChanged(enabled: Bool) {
    if enabled {
      awaitingOptIn = false
    }
  }
}
