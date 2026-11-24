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

  public func listText(displayPath: (String) -> String = { $0 }) -> String {
    items.map { "\(displayPath($0.path)): \($0.reason)" }.joined(separator: "\n")
  }

  public static func collect(stderr: String, snapshotMounts: [String] = [], limit: Int = itemLimit)
    -> BackupWarnings
  {
    var warnings = BackupWarnings()
    var seen = Set<String>()
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    for rawLine in stderr.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("{"),
        let error = try? decoder.decode(ItemErrorLine.self, from: Data(line.utf8)),
        error.messageType == "error",
        let item = error.item, !item.isEmpty,
        let message = error.error?.message
      else { continue }
      let path = livePath(of: item, snapshotMounts: snapshotMounts)
      guard seen.insert(path).inserted else { continue }
      warnings.total += 1
      if warnings.items.count < limit {
        warnings.items.append(
          BackupWarning(path: path, reason: reason(from: message, item: item, path: path)))
      }
    }
    return warnings
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

private struct ItemErrorLine: Decodable {
  struct Payload: Decodable {
    var message: String?
  }

  var messageType: String
  var error: Payload?
  var item: String?
}
