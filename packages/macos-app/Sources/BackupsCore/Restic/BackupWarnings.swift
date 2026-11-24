import Foundation

public struct BackupWarning: Codable, Equatable, Sendable {
  public var path: String
  public var reason: String

  public init(path: String, reason: String) {
    self.path = path
    self.reason = reason
  }
}

public struct BackupWarnings: Codable, Equatable, Sendable {
  public static let itemLimit = 500

  public var items: [BackupWarning]
  public var total: Int

  public init(items: [BackupWarning] = [], total: Int = 0) {
    self.items = items
    self.total = total
  }

  public var isTruncated: Bool { total > items.count }

  public var summary: String? {
    guard total > 0 else { return nil }
    return total == 1 ? "1 file couldn't be backed up." : "\(total) files couldn't be backed up."
  }

  public static func livePaths(in text: String, snapshotMounts: [String]) -> String {
    snapshotMounts.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) { result, mount in
      result.replacingOccurrences(of: mount + "/", with: "/")
    }
  }

  public func listText() -> String {
    items.map { "\(Self.escapingLineBreaks($0.path)): \(Self.escapingLineBreaks($0.reason))" }
      .joined(separator: "\n")
  }

  static func escapingLineBreaks(_ text: String) -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
  }

  public static func collect(stderr: String, snapshotMounts: [String] = [], limit: Int = itemLimit)
    -> BackupWarnings
  {
    var collector = Collector(limit: limit)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    for record in stderr.utf8.split(separator: UInt8(ascii: "\n")) {
      let line = String(decoding: record.last == UInt8(ascii: "\r") ? record.dropLast() : record, as: UTF8.self)
      if let skipped = skippedSource(in: line) {
        collector.add(path: livePath(of: skipped.item, snapshotMounts: snapshotMounts), reason: skipped.reason)
        continue
      }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("{"),
        let error = try? decoder.decode(ItemErrorLine.self, from: Data(trimmed.utf8)),
        error.messageType == "error",
        let item = error.item, !item.isEmpty,
        let message = error.error?.message
      else { continue }
      let path = livePath(of: item, snapshotMounts: snapshotMounts)
      collector.add(
        path: path, reason: reason(from: message, item: item, path: path), duringScan: error.during == "scan")
    }
    return collector.warnings
  }

  private static let sourceSkipReasons = [
    (suffix: " does not exist, skipping", reason: "Does not exist"),
    (suffix: " cannot be accessed, skipping", reason: "Cannot be accessed"),
  ]

  static func skippedSource(in line: String) -> (item: String, reason: String)? {
    guard !line.hasPrefix("{") else { return nil }
    for skip in sourceSkipReasons where line.hasSuffix(skip.suffix) && line.count > skip.suffix.count {
      return (String(line.dropLast(skip.suffix.count)), skip.reason)
    }
    return nil
  }

  static func livePath(of item: String, snapshotMounts: [String]) -> String {
    guard item.hasPrefix("/") else {
      return item == "." ? "/" : "/" + item
    }
    for mount in snapshotMounts where !mount.isEmpty {
      if item == mount {
        return "/"
      }
      if item.hasPrefix(mount + "/") {
        return "/" + item.dropFirst(mount.count + 1)
      }
    }
    return item
  }

  static func reason(from message: String, item: String, path: String) -> String {
    let spellings = Set([item, path, String(path.dropFirst())]).filter { $0.count > 1 }
    var start = message.startIndex
    for spelling in spellings {
      var searchStart = message.startIndex
      while let match = message.range(of: spelling + ": ", range: searchStart..<message.endIndex) {
        start = max(start, match.upperBound)
        searchStart = match.upperBound
      }
    }
    let remainder = message[start...].trimmingCharacters(in: .whitespaces)
    let reason = remainder.isEmpty ? message.trimmingCharacters(in: .whitespaces) : remainder
    return reason.prefix(1).uppercased() + reason.dropFirst()
  }
}

extension RunRecord {
  public func warnings(forSnapshot snapshotId: String) -> BackupWarnings? {
    self.snapshotId == snapshotId ? warnings : nil
  }
}

private struct Collector {
  let limit: Int
  var warnings = BackupWarnings()
  var seen = Set<String>()
  var scanReasonIndices: [String: Int] = [:]

  init(limit: Int) {
    self.limit = limit
  }

  mutating func add(path: String, reason: @autoclosure () -> String, duringScan: Bool = false) {
    guard seen.insert(path).inserted else {
      if !duringScan, let index = scanReasonIndices.removeValue(forKey: path) {
        warnings.items[index].reason = reason()
      }
      return
    }
    warnings.total += 1
    guard warnings.items.count < limit else { return }
    if duringScan {
      scanReasonIndices[path] = warnings.items.count
    }
    warnings.items.append(BackupWarning(path: path, reason: reason()))
  }
}

private struct ItemErrorLine: Decodable {
  struct Payload: Decodable {
    var message: String?
  }

  var messageType: String
  var error: Payload?
  var item: String?
  var during: String?
}
