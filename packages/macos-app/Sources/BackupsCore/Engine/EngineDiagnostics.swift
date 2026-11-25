import Foundation
import os

public enum EngineDiagnostics {
  private static let logger = Logger(subsystem: "org.futo.backups.mac", category: "engine")

  public static func logUnreportedFailure(_ error: any Error) {
    let nsError = error as NSError
    logger.error(
      "Backup failed before reaching the server: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(label(of: error), privacy: .public)"
    )
  }

  static func label(of error: any Error) -> String {
    let type = String(describing: Swift.type(of: error))
    guard Mirror(reflecting: error).displayStyle == .enum else { return type }
    guard let caseName = Mirror(reflecting: error).children.first?.label else {
      return "\(type).\(error)"
    }
    return "\(type).\(caseName)"
  }
}
