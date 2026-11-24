import Foundation

public struct RestoreProgress: Equatable, Sendable {
  public var percentDone: Double
  public var totalFiles: Int
  public var filesRestored: Int
  public var totalBytes: Int64
  public var bytesRestored: Int64

  public init(
    percentDone: Double = 0, totalFiles: Int = 0, filesRestored: Int = 0, totalBytes: Int64 = 0,
    bytesRestored: Int64 = 0
  ) {
    self.percentDone = percentDone
    self.totalFiles = totalFiles
    self.filesRestored = filesRestored
    self.totalBytes = totalBytes
    self.bytesRestored = bytesRestored
  }

  // restic keeps adding to the totals while it walks the snapshot tree, before it writes anything.
  public var hasStarted: Bool {
    filesRestored > 0 || bytesRestored > 0
  }

  public static func parse(_ line: String) -> RestoreProgress? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    guard let data = line.data(using: .utf8), let status = try? decoder.decode(RestoreStatusLine.self, from: data)
    else { return nil }
    let percentDone: Double
    switch status.messageType {
    case "status": percentDone = status.percentDone ?? 0
    case "summary": percentDone = 1
    default: return nil
    }
    return RestoreProgress(
      percentDone: percentDone,
      totalFiles: status.totalFiles ?? 0,
      filesRestored: status.filesRestored ?? 0,
      totalBytes: status.totalBytes ?? 0,
      bytesRestored: status.bytesRestored ?? 0)
  }
}

private struct RestoreStatusLine: Decodable {
  var messageType: String
  var percentDone: Double?
  var totalFiles: Int?
  var filesRestored: Int?
  var totalBytes: Int64?
  var bytesRestored: Int64?
}
