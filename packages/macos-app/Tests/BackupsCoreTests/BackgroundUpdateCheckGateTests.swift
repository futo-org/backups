import BackupsCore
import Testing

@Test func anAlreadyOnboardedUserAllowsBackgroundChecks() {
  #expect(BackgroundUpdateCheckGate(onboarding: false).allowsBackgroundChecks)
}

@Test func onboardingHoldsBackgroundChecksEvenWhenAutomaticChecksAreTurnedOn() {
  var gate = BackgroundUpdateCheckGate(onboarding: true)
  #expect(!gate.allowsBackgroundChecks)

  gate.automaticChecksChanged(enabled: true)
  #expect(!gate.allowsBackgroundChecks)
}

@Test func finishingOnboardingWithAutomaticChecksAllowsBackgroundChecks() {
  var gate = BackgroundUpdateCheckGate(onboarding: true)
  gate.finishOnboarding(automaticChecks: true)
  #expect(gate.allowsBackgroundChecks)
}

@Test func finishingOnboardingWithoutAutomaticChecksHoldsBackgroundChecksUntilTheyAreTurnedOn() {
  var gate = BackgroundUpdateCheckGate(onboarding: true)
  gate.finishOnboarding(automaticChecks: false)
  #expect(!gate.allowsBackgroundChecks)

  gate.automaticChecksChanged(enabled: false)
  #expect(!gate.allowsBackgroundChecks)

  gate.automaticChecksChanged(enabled: true)
  #expect(gate.allowsBackgroundChecks)
}
