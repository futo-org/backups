import Foundation

public struct BackupProgress: Equatable, Sendable {
  public var percentDone: Double
  public var totalFiles: Int
  public var filesDone: Int
  public var totalBytes: Int64
  public var bytesDone: Int64
  public var secondsRemaining: Int?

  init(
    percentDone: Double = 0, totalFiles: Int = 0, filesDone: Int = 0, totalBytes: Int64 = 0, bytesDone: Int64 = 0,
    secondsRemaining: Int? = nil
  ) {
    self.percentDone = percentDone
    self.totalFiles = totalFiles
    self.filesDone = filesDone
    self.totalBytes = totalBytes
    self.bytesDone = bytesDone
    self.secondsRemaining = secondsRemaining
  }
}

public struct BackupSummary: Equatable, Sendable, Codable {
  public var filesNew: Int
  public var filesChanged: Int
  public var filesUnmodified: Int
  public var dataAdded: Int64
  public var totalFilesProcessed: Int
  public var totalBytesProcessed: Int64
  public var snapshotId: String?

  init(
    filesNew: Int = 0, filesChanged: Int = 0, filesUnmodified: Int = 0, dataAdded: Int64 = 0,
    totalFilesProcessed: Int = 0, totalBytesProcessed: Int64 = 0, snapshotId: String? = nil
  ) {
    self.filesNew = filesNew
    self.filesChanged = filesChanged
    self.filesUnmodified = filesUnmodified
    self.dataAdded = dataAdded
    self.totalFilesProcessed = totalFilesProcessed
    self.totalBytesProcessed = totalBytesProcessed
    self.snapshotId = snapshotId
  }
}

public enum ResticMessage: Equatable, Sendable {
  case status(BackupProgress)
  case summary(BackupSummary)
  case error(String)
  case other
}

public struct Snapshot: Equatable, Sendable, Identifiable {
  public var id: String
  public var shortId: String
  public var time: Date
  public var paths: [String]
  public var hostname: String
  public var tags: [String]
  public var totalFilesProcessed: Int?
  public var totalBytesProcessed: Int64?
  public var dataAdded: Int64?

  init(
    id: String, shortId: String, time: Date, paths: [String], hostname: String, tags: [String],
    totalFilesProcessed: Int?, totalBytesProcessed: Int64?, dataAdded: Int64?
  ) {
    self.id = id
    self.shortId = shortId
    self.time = time
    self.paths = paths
    self.hostname = hostname
    self.tags = tags
    self.totalFilesProcessed = totalFilesProcessed
    self.totalBytesProcessed = totalBytesProcessed
    self.dataAdded = dataAdded
  }
}

public enum ResticOutput {
  public static func parseLine(_ line: String) -> ResticMessage {
    guard let data = line.data(using: .utf8), let kind = try? makeDecoder().decode(MessageKind.self, from: data)
    else { return .other }
    switch kind.messageType {
    case "status":
      guard let status = try? makeDecoder().decode(StatusLine.self, from: data) else { return .other }
      return .status(
        BackupProgress(
          percentDone: status.percentDone ?? 0,
          totalFiles: status.totalFiles ?? 0,
          filesDone: status.filesDone ?? 0,
          totalBytes: status.totalBytes ?? 0,
          bytesDone: status.bytesDone ?? 0,
          secondsRemaining: status.secondsRemaining))
    case "summary":
      guard let summary = try? makeDecoder().decode(SummaryLine.self, from: data) else { return .other }
      return .summary(
        BackupSummary(
          filesNew: summary.filesNew ?? 0,
          filesChanged: summary.filesChanged ?? 0,
          filesUnmodified: summary.filesUnmodified ?? 0,
          dataAdded: summary.dataAdded ?? 0,
          totalFilesProcessed: summary.totalFilesProcessed ?? 0,
          totalBytesProcessed: summary.totalBytesProcessed ?? 0,
          snapshotId: summary.snapshotId))
    case "error":
      guard let error = try? makeDecoder().decode(ErrorLine.self, from: data), let message = error.error?.message
      else { return .other }
      if let item = error.item {
        return .error("\(item): \(message)")
      }
      return .error(message)
    default:
      return .other
    }
  }

  public static func parseSnapshots(_ data: Data) throws -> [Snapshot] {
    let lines = try makeDecoder().decode([SnapshotLine].self, from: data)
    return try lines.map { line in
      guard let time = parseTimestamp(line.time) else { throw SnapshotTimeError() }
      return Snapshot(
        id: line.id,
        shortId: line.shortId,
        time: time,
        paths: line.paths,
        hostname: line.hostname,
        tags: line.tags ?? [],
        totalFilesProcessed: line.summary?.totalFilesProcessed,
        totalBytesProcessed: line.summary?.totalBytesProcessed,
        dataAdded: line.summary?.dataAdded)
    }
  }

  public static func parseStatsTotalSize(_ data: Data) throws -> Int64 {
    try makeDecoder().decode(StatsLine.self, from: data).totalSize
  }

  public static func parseVersion(_ data: Data) throws -> String {
    try makeDecoder().decode(VersionLine.self, from: data).version
  }

  public static func errorMessage(stderr: String, exitCode: Int32) -> String {
    var lastErrorMessage: String?
    var lastLine: String?
    for rawLine in stderr.components(separatedBy: .newlines) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      lastLine = line
      guard let data = line.data(using: .utf8),
        let kind = try? makeDecoder().decode(MessageKind.self, from: data)
      else { continue }
      switch kind.messageType {
      case "exit_error":
        if let exitError = try? makeDecoder().decode(ExitErrorLine.self, from: data) {
          return exitError.message
        }
      case "error":
        if let error = try? makeDecoder().decode(ErrorLine.self, from: data), let message = error.error?.message {
          lastErrorMessage = error.item.map { "\($0): \(message)" } ?? message
        }
      default:
        break
      }
    }
    if let lastErrorMessage { return lastErrorMessage }
    if let lastLine { return lastLine }
    return "restic exited with code \(exitCode)"
  }

  private static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  private static func parseTimestamp(_ text: String) -> Date? {
    if let truncated = truncateFraction(text) {
      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return formatter.date(from: truncated)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: text)
  }

  private static func truncateFraction(_ text: String) -> String? {
    guard let dot = text.firstIndex(of: ".") else { return nil }
    var index = text.index(after: dot)
    var digits = ""
    while index < text.endIndex, text[index].isNumber, digits.count < 3 {
      digits.append(text[index])
      index = text.index(after: index)
    }
    while index < text.endIndex, text[index].isNumber {
      index = text.index(after: index)
    }
    while digits.count < 3 {
      digits.append("0")
    }
    return String(text[text.startIndex..<dot]) + "." + digits + String(text[index...])
  }
}

public enum ResticExitCode {
  public static let success: Int32 = 0
  public static let couldNotReadSource: Int32 = 3
  public static let repositoryDoesNotExist: Int32 = 10
  public static let lockFailed: Int32 = 11
  public static let wrongPassword: Int32 = 12
}

private struct SnapshotTimeError: Error {}

private struct MessageKind: Decodable {
  var messageType: String
}

private struct StatusLine: Decodable {
  var percentDone: Double?
  var totalFiles: Int?
  var filesDone: Int?
  var totalBytes: Int64?
  var bytesDone: Int64?
  var secondsRemaining: Int?
}

private struct SummaryLine: Decodable {
  var filesNew: Int?
  var filesChanged: Int?
  var filesUnmodified: Int?
  var dataAdded: Int64?
  var totalFilesProcessed: Int?
  var totalBytesProcessed: Int64?
  var snapshotId: String?
}

private struct ErrorLine: Decodable {
  struct Payload: Decodable {
    var message: String?
  }

  var error: Payload?
  var item: String?
}

private struct ExitErrorLine: Decodable {
  var message: String
}

private struct SnapshotLine: Decodable {
  struct Summary: Decodable {
    var totalFilesProcessed: Int?
    var totalBytesProcessed: Int64?
    var dataAdded: Int64?
  }

  var id: String
  var shortId: String
  var time: String
  var paths: [String]
  var hostname: String
  var tags: [String]?
  var summary: Summary?
}

private struct StatsLine: Decodable {
  var totalSize: Int64
}

private struct VersionLine: Decodable {
  var version: String
}
