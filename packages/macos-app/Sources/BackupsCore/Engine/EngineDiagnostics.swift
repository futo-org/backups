import Foundation
import os

public enum EngineDiagnostics {
  private static let logger = Logger(subsystem: "org.futo.backups.mac", category: "engine")

  public static func logUnreportedFailure(_ error: any Error) {
    let nsError = error as NSError
    logger.error(
      "Backup failed before reaching the server: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) \(String(describing: error), privacy: .private)"
    )
  }
}
