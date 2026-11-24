import Foundation

public struct ExcludePattern: Sendable, Equatable {
  public typealias Component = [Unicode.Scalar]

  private enum Part: Sendable, Equatable {
    case root
    case anyDepth
    case literal(Component)
    case glob(Component)
  }

  private static let rootComponent: Component = ["/"]
  private static let globCharacters: Set<Unicode.Scalar> = ["\\", "[", "]", "*", "?"]

  private let parts: [Part]
  private let lastLiteral: Component?

  public init?(_ pattern: String) {
    guard !pattern.isEmpty, !pattern.hasPrefix("!") else { return nil }
    var parts: [Part] = []
    for component in Self.components(of: pattern) {
      if component == Self.rootComponent {
        parts.append(.root)
      } else if component == ["*", "*"] {
        parts.append(.anyDepth)
      } else if component.contains(where: Self.globCharacters.contains) {
        guard Self.isValidGlob(component) else { return nil }
        parts.append(.glob(component))
      } else {
        parts.append(.literal(component))
      }
    }
    self.parts = parts
    if case .literal(let literal) = parts.last {
      lastLiteral = literal
    } else {
      lastLiteral = nil
    }
  }

  public func matches(_ path: String) -> Bool {
    Self.match(parts[...], Self.components(of: path), endAnchored: false)
  }

  func matches(components: [Component], endAnchored: Bool) -> Bool {
    if endAnchored, let lastLiteral, components.last != lastLiteral {
      return false
    }
    return Self.match(parts[...], components, endAnchored: endAnchored)
  }

  static func components(of path: String) -> [Component] {
    let cleaned = cleanPath(path)
    var parts = cleaned.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map(Array.init)
    if parts.first?.isEmpty == true {
      parts[0] = rootComponent
    }
    if parts.count == 2, parts[1].isEmpty {
      parts.removeLast()
    }
    return parts
  }

  static func cleanPath(_ path: String) -> String {
    guard !path.isEmpty else { return "." }
    let rooted = path.hasPrefix("/")
    var kept: [Substring] = []
    for component in path.split(separator: "/") {
      switch component {
      case ".":
        continue
      case "..":
        if let last = kept.last, last != ".." {
          kept.removeLast()
        } else if !rooted {
          kept.append(component)
        }
      default:
        kept.append(component)
      }
    }
    let joined = kept.joined(separator: "/")
    if rooted {
      return "/" + joined
    }
    return joined.isEmpty ? "." : joined
  }

  private static func match(_ parts: ArraySlice<Part>, _ path: [Component], endAnchored: Bool) -> Bool {
    if let wildcard = parts.firstIndex(of: .anyDepth) {
      let prefix = parts[..<wildcard]
      let suffix = parts[(wildcard + 1)...]
      let maxStars = path.count - parts.count + 1
      guard maxStars >= 0 else { return false }
      for stars in 0...maxStars {
        let expanded = prefix + repeatElement(Part.glob(["*"]), count: stars) + suffix
        if match(expanded, path, endAnchored: endAnchored) {
          return true
        }
      }
      return false
    }
    guard !parts.isEmpty, !path.isEmpty, parts.count <= path.count else { return false }
    var minOffset = 0
    var maxOffset = path.count - parts.count
    if parts.first == .root {
      maxOffset = 0
    } else if path[0] == rootComponent {
      minOffset = 1
    }
    if endAnchored {
      minOffset = max(minOffset, path.count - parts.count)
    }
    guard minOffset <= maxOffset else { return false }
    for offset in stride(from: maxOffset, through: minOffset, by: -1)
    where zip(parts, path[offset...]).allSatisfy({ partMatches($0, $1) }) {
      return true
    }
    return false
  }

  private static func partMatches(_ part: Part, _ component: Component) -> Bool {
    switch part {
    case .root: component == rootComponent
    case .anyDepth: false
    case .literal(let literal): literal == component
    case .glob(let pattern): globMatches(pattern, component)
    }
  }

  private static func globMatches(_ pattern: Component, _ name: Component) -> Bool {
    var patternIndex = 0
    var nameIndex = 0
    var starPattern: Int?
    var starName = 0
    while nameIndex < name.count {
      if patternIndex < pattern.count, let next = step(pattern, patternIndex, name[nameIndex]) {
        if pattern[patternIndex] == "*" {
          starPattern = patternIndex
          starName = nameIndex
          patternIndex += 1
          continue
        }
        patternIndex = next
        nameIndex += 1
        continue
      }
      guard let starPattern else { return false }
      starName += 1
      nameIndex = starName
      patternIndex = starPattern + 1
    }
    while patternIndex < pattern.count, pattern[patternIndex] == "*" {
      patternIndex += 1
    }
    return patternIndex == pattern.count
  }

  private static func step(_ pattern: Component, _ index: Int, _ character: Unicode.Scalar) -> Int? {
    switch pattern[index] {
    case "*":
      return index
    case "?":
      return index + 1
    case "[":
      guard let parsed = parseClass(pattern, from: index) else { return nil }
      let inClass = parsed.ranges.contains { $0.contains(character) }
      return inClass != parsed.negated ? parsed.end : nil
    case "\\":
      return index + 1 < pattern.count && pattern[index + 1] == character ? index + 2 : nil
    default:
      return pattern[index] == character ? index + 1 : nil
    }
  }

  private static func parseClass(_ pattern: Component, from start: Int)
    -> (ranges: [ClosedRange<Unicode.Scalar>], negated: Bool, end: Int)?
  {
    var index = start + 1
    var negated = false
    if index < pattern.count, pattern[index] == "^" {
      negated = true
      index += 1
    }
    var ranges: [ClosedRange<Unicode.Scalar>] = []
    while true {
      if index < pattern.count, pattern[index] == "]", !ranges.isEmpty {
        return (ranges, negated, index + 1)
      }
      guard let low = classCharacter(pattern, at: &index) else { return nil }
      var high = low
      if index < pattern.count, pattern[index] == "-" {
        index += 1
        guard let upper = classCharacter(pattern, at: &index) else { return nil }
        high = upper
      }
      guard low <= high else { return nil }
      ranges.append(low...high)
    }
  }

  private static func classCharacter(_ pattern: Component, at index: inout Int) -> Unicode.Scalar? {
    guard index < pattern.count, pattern[index] != "-", pattern[index] != "]" else { return nil }
    if pattern[index] == "\\" {
      index += 1
      guard index < pattern.count else { return nil }
    }
    defer { index += 1 }
    return pattern[index]
  }

  private static func isValidGlob(_ pattern: Component) -> Bool {
    var index = 0
    while index < pattern.count {
      switch pattern[index] {
      case "\\":
        guard index + 1 < pattern.count else { return false }
        index += 2
      case "[":
        guard let parsed = parseClass(pattern, from: index) else { return false }
        index = parsed.end
      default:
        index += 1
      }
    }
    return true
  }
}
