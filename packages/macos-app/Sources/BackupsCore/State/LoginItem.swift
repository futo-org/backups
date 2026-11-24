public enum LoginItemStatus: Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
}

public enum LoginItemChange: Equatable, Sendable {
  case none
  case register
  case unregister
  case askForApproval

  public static func toward(openAtLogin wanted: Bool, from status: LoginItemStatus) -> LoginItemChange {
    switch (wanted, status) {
    case (true, .enabled), (false, .notRegistered), (false, .notFound): .none
    case (true, .requiresApproval): .askForApproval
    case (true, .notRegistered), (true, .notFound): .register
    case (false, .enabled), (false, .requiresApproval): .unregister
    }
  }
}
