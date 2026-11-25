import Foundation

public struct RestoreStep: Equatable, Sendable {
  public var part: Int
  public var partCount: Int
  public var name: String
  public var progress: RestoreProgress?

  public init(part: Int, partCount: Int, name: String, progress: RestoreProgress? = nil) {
    self.part = part
    self.partCount = partCount
    self.name = name
    self.progress = progress
  }

  public var title: String {
    partCount > 1 ? "Restoring \(part) of \(partCount)" : "Restoring"
  }

  public var fraction: Double? {
    guard let progress, progress.hasStarted else { return nil }
    return progress.fractionDone
  }

  public var overallFraction: Double? {
    partCount == 1 ? fraction : nil
  }

  public func subtitle(
    namingPart: Bool = true, locale: Locale = .current, formatBytes: (Int64) -> String
  ) -> String {
    var parts = namingPart && partCount > 1 ? [name] : []
    if let progress, progress.hasStarted {
      let files = progress.filesRestored.formatted(.number.locale(locale))
      let total = progress.totalFiles.formatted(.number.locale(locale))
      if progress.totalBytes > 0 {
        parts.append("\(formatBytes(progress.bytesRestored)) of \(formatBytes(progress.totalBytes))")
      }
      parts.append("\(files) of \(total) \(progress.totalFiles == 1 ? "item" : "items")")
    } else {
      parts.append("Bringing your files back")
    }
    return parts.joined(separator: " · ")
  }
}
