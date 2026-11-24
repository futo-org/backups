import Foundation

public enum ExclusionError: Error, Equatable, Sendable {
  case empty
  case alreadyExcluded
}

public enum Exclusions {
  public static func defaults(home: String) -> [String] {
    AppConfig.defaultExcludes.map { expandHome($0, home: home) }
  }

  public static func isDefault(_ pattern: String, home: String) -> Bool {
    defaults(home: home).contains(pattern)
  }

  public static func pattern(forPath path: String) -> String {
    var escaped = ""
    for character in path {
      if "\\*?[".contains(character) {
        escaped.append("\\")
      }
      escaped.append(character)
    }
    return escaped
  }

  public static func normalizedPattern(_ input: String, home: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let expanded = expandHome(trimmed, home: home)
    guard expanded.count > 1, expanded.hasSuffix("/") else { return expanded }
    return String(expanded.dropLast())
  }

  public static func adding(_ patterns: [String], to excludes: [String]) throws -> [String] {
    let fresh = patterns.filter { !excludes.contains($0) }
    if fresh.isEmpty {
      throw patterns.isEmpty ? ExclusionError.empty : ExclusionError.alreadyExcluded
    }
    var result = excludes
    for pattern in fresh where !result.contains(pattern) {
      result.append(pattern)
    }
    return result
  }

  public static func isExcluded(_ path: String, by excludes: [String]) -> Bool {
    excludes.reduce(false) { excluded, exclude in
      if exclude.hasPrefix("!") {
        return excluded && ExcludePattern(String(exclude.dropFirst()))?.matches(path) != true
      }
      return excluded || ExcludePattern(exclude)?.matches(path) == true
    }
  }

  public static func excluding(_ paths: [String], in excludes: [String]) -> [String] {
    var result = excludes
    for path in paths where !isExcluded(path, by: result) {
      let literal = pattern(forPath: path)
      result.removeAll { $0 == literal }
      result.append(literal)
    }
    return result
  }

  public static func wouldExcludeAnyFolder(_ path: String, folders: [String]) -> Bool {
    [{ $0 }, dataVolumeSpelling].contains { spelling in
      guard let exclusion = ExcludePattern(pattern(forPath: spelling(path))) else { return false }
      return folders.map(spelling).contains(where: exclusion.matches)
    }
  }

  private static func dataVolumeSpelling(_ path: String) -> String {
    guard let relative = DataVolume.snapshotRelativePath(path) else { return path }
    return relative == "." ? "/" : "/" + relative
  }

  public static func restoringDefaults(in excludes: [String], home: String) -> [String] {
    let missing = defaults(home: home).filter { !excludes.contains($0) }
    return missing + excludes
  }

  private static func expandHome(_ pattern: String, home: String) -> String {
    if pattern == "~" {
      return home
    }
    return pattern.hasPrefix("~/") ? home + pattern.dropFirst() : pattern
  }
}
