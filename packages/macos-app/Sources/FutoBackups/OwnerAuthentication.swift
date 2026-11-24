import LocalAuthentication

enum OwnerAuthenticationResult {
  case confirmed
  case declined
  case unavailable
}

@MainActor
enum OwnerAuthentication {
  static let unavailableMessage = "This Mac can't confirm it's you right now, so the recovery key stays protected."

  static func confirm(reason: String) async -> OwnerAuthenticationResult {
    let context = LAContext()
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .unavailable }
    let confirmed = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    return confirmed ? .confirmed : .declined
  }
}
