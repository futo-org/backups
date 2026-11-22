import Foundation

public struct Throttle: Codable, Equatable, Hashable, Sendable {
  public var bytesPerSec: Int
  public var quietHours: String

  public init(bytesPerSec: Int = 0, quietHours: String = "") {
    self.bytesPerSec = bytesPerSec
    self.quietHours = quietHours
  }

  public static let unthrottled = Throttle()
}

public enum BackupStatus: String, Codable, Sendable, CaseIterable {
  case incomplete, complete, warn, failed, cancelled, skipped
}
