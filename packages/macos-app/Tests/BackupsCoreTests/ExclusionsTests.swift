import Foundation
import Testing

@testable import BackupsCore

private let home = "/Users/test"

@Test func defaultsExpandTheHomeFolder() {
  let defaults = Exclusions.defaults(home: home)
  #expect(defaults.contains("/Users/test/Library/Caches"))
  #expect(defaults.contains("**/node_modules"))
  #expect(defaults == AppConfig.defaults(host: "mac", home: home).excludes)
  #expect(Exclusions.isDefault("/Users/test/.Trash", home: home))
  #expect(!Exclusions.isDefault("/Users/test/Movies", home: home))
}

@Test(
  "picked paths become literal patterns",
  arguments: [
    ("/Users/test/Movies", "/Users/test/Movies"),
    ("/Users/test/Old [2019]/*draft?", "/Users/test/Old \\[2019]/\\*draft\\?"),
    ("/Users/test/back\\slash", "/Users/test/back\\\\slash"),
  ])
func literalPatterns(path: String, expected: String) {
  #expect(Exclusions.pattern(forPath: path) == expected)
}

@Test func escapedPatternsMatchOnlyTheLiteralPath() {
  let pattern = Exclusions.pattern(forPath: "/Users/test/Old [2019]/*")
  #expect(fnmatch(pattern, "/Users/test/Old [2019]/*", FNM_PATHNAME) == 0)
  #expect(fnmatch(pattern, "/Users/test/Old 2/report", FNM_PATHNAME) != 0)
}

@Test(
  "typed patterns are trimmed and expand ~",
  arguments: [
    ("  *.iso  ", "*.iso"),
    ("~/Downloads/Old", "/Users/test/Downloads/Old"),
    ("~/Downloads/Old/", "/Users/test/Downloads/Old"),
    ("~", "/Users/test"),
    ("**/build", "**/build"),
    ("/", "/"),
  ])
func typedPatterns(input: String, expected: String) {
  #expect(Exclusions.normalizedPattern(input, home: home) == expected)
}

@Test func blankPatternsAreRejected() {
  #expect(Exclusions.normalizedPattern("   ", home: home) == nil)
  #expect(Exclusions.normalizedPattern("", home: home) == nil)
}

@Test func addingKeepsOrderAndRejectsDuplicates() throws {
  let start = ["**/node_modules"]
  #expect(
    try Exclusions.adding(["*.iso", "*.iso", "**/build"], to: start) == ["**/node_modules", "*.iso", "**/build"])
  #expect(throws: ExclusionError.alreadyExcluded) { try Exclusions.adding(["**/node_modules"], to: start) }
  #expect(throws: ExclusionError.empty) { try Exclusions.adding([], to: start) }
}

@Test func restoringDefaultsPutsMissingOnesBackFirst() {
  let custom = ["*.iso", "/Users/test/.Trash"]
  let restored = Exclusions.restoringDefaults(in: custom, home: home)
  #expect(Set(restored) == Set(Exclusions.defaults(home: home) + ["*.iso"]))
  #expect(restored.suffix(2) == ["*.iso", "/Users/test/.Trash"])
  #expect(restored.filter { $0 == "/Users/test/.Trash" }.count == 1)
}
