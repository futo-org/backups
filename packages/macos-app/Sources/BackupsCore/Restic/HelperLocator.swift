import Foundation

public enum Helper: String, Sendable, CaseIterable {
  case restic = "restic"
  case resticProxy = "restic-proxy"

  public var environmentKey: String {
    switch self {
    case .restic: "FUTO_BACKUPS_RESTIC"
    case .resticProxy: "FUTO_BACKUPS_RESTIC_PROXY"
    }
  }
}

public enum HelperLocator {
  public static func locate(
    _ helper: Helper,
    bundleURL: URL = Bundle.main.bundleURL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL? {
    if let path = environment[helper.environmentKey], FileManager.default.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    let bundled =
      bundleURL
      .appendingPathComponent("Contents")
      .appendingPathComponent("Helpers")
      .appendingPathComponent(helper.rawValue)
    if FileManager.default.isExecutableFile(atPath: bundled.path) {
      return bundled
    }
    return nil
  }
}
