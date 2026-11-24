import Foundation

public struct QuitEvent: Equatable, Sendable {
  public var hasQuitReason: Bool
  public var senderBundleIdentifier: String?

  public init(hasQuitReason: Bool, senderBundleIdentifier: String?) {
    self.hasQuitReason = hasQuitReason
    self.senderBundleIdentifier = senderBundleIdentifier
  }
}

public enum QuitDecision: Equatable, Sendable {
  case quit
  case stayInMenuBar
}

public struct QuitPolicy: Equatable, Sendable {
  public static let dockBundleIdentifier = "com.apple.dock"

  public private(set) var quitChosen = false
  public private(set) var updateRelaunching = false

  public init() {}

  public mutating func chooseQuit() {
    quitChosen = true
  }

  public mutating func updateWillRelaunch() {
    updateRelaunching = true
  }

  public mutating func updateCycleEnded() {
    updateRelaunching = false
  }

  public func decision(for event: QuitEvent?) -> QuitDecision {
    if quitChosen || updateRelaunching {
      return .quit
    }
    guard let event else { return .stayInMenuBar }
    return event.hasQuitReason || event.senderBundleIdentifier != Self.dockBundleIdentifier ? .quit : .stayInMenuBar
  }
}
