import Testing

@testable import BackupsCore

@Test(
  "matches like restic's exclude filter",
  arguments: [
    ("*.go", "/foo/bar/test.go", true),
    ("*.go", "/foo/bar/test.go.bak", false),
    ("bar", "/foo/bar/test.go", true),
    ("/bar", "/foo/bar/test.go", false),
    ("/foo", "/foo/bar/test.go", true),
    ("/foo/bar", "/foo", false),
    ("foo/bar", "/x/foo/bar/y", true),
    ("**/node_modules", "/a/b/node_modules", true),
    ("**/node_modules", "/node_modules", true),
    ("**/node_modules", "/a/node_modules_old", false),
    ("**/.DS_Store", "/Users/x/Documents/.DS_Store", true),
    ("foo/**/bar", "/x/foo/bar", true),
    ("foo/**/bar", "/x/foo/a/b/bar", true),
    ("foo/**/bar", "/x/foo/a/b/baz", false),
    ("/Users/x/**", "/Users/x/a/b", true),
    (
      "/Users/x/Library/Containers/*/Data/Library/Caches", "/Users/x/Library/Containers/com.a/Data/Library/Caches", true
    ),
    ("/Users/x/Library/Containers/*/Data/Library/Caches", "/Users/x/Library/Containers/com.a/Data/Library", false),
    ("/Users/x/Library/Caches", "/Users/x/Library/Caches/com.app/file", true),
    ("/Users/x/Library/Caches", "/Users/x/Library/CachesOld", false),
    ("[a-c]at", "/x/bat", true),
    ("[^a-c]at", "/x/bat", false),
    ("ca?", "/x/cat", true),
    ("\\*", "/x/*", true),
    ("\\*", "/x/a", false),
    ("~/Documents", "/Users/x/Documents", false),
    ("/foo/../bar/", "/bar/x", true),
    ("Café", "/x/Cafe\u{301}", false),
  ])
func matchesLikeRestic(pattern: String, path: String, expected: Bool) throws {
  let compiled = try #require(ExcludePattern(pattern))
  #expect(compiled.matches(path) == expected)
}

@Test(arguments: ["", "!keep", "[", "[]a]", "[z-a]", "trailing\\"])
func rejectsPatternsResticWouldNotExclude(pattern: String) {
  #expect(ExcludePattern(pattern) == nil)
}

@Test func endAnchoredMatchingOnlyAcceptsMatchesEndingAtTheLastComponent() throws {
  let pattern = try #require(ExcludePattern("/foo"))
  let child = ExcludePattern.components(of: "/foo/bar")
  #expect(pattern.matches(components: child, endAnchored: false))
  #expect(!pattern.matches(components: child, endAnchored: true))
  #expect(pattern.matches(components: ExcludePattern.components(of: "/foo"), endAnchored: true))
  let glob = try #require(ExcludePattern("**/node_modules"))
  #expect(glob.matches(components: ExcludePattern.components(of: "/a/node_modules"), endAnchored: true))
  #expect(!glob.matches(components: ExcludePattern.components(of: "/a/node_modules/x"), endAnchored: true))
}

@Test(
  arguments: [
    ("/", "/"), ("/a/./b/../c/", "/a/c"), ("a//b", "a/b"), ("../a", "../a"), ("/../a", "/a"), ("", "."),
    ("./", "."),
  ])
func cleanPathMatchesGo(path: String, expected: String) {
  #expect(ExcludePattern.cleanPath(path) == expected)
}
