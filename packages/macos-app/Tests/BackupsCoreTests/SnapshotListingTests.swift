import Foundation
import Testing

@testable import BackupsCore

private let snapshotLine =
  #"{"time":"2026-11-24T13:24:49.732508-05:00","tree":"b0a4","paths":["/Users/x/Docs"],"hostname":"mac","#
  + #""id":"ce0c1cef","short_id":"ce0c1cef","message_type":"snapshot","struct_type":"snapshot"}"#

private func node(_ name: String, _ type: String, _ path: String, size: Int? = nil, mtime: String? = nil) -> String {
  var fields = [
    #""name":"\#(name)""#, #""type":"\#(type)""#, #""path":"\#(path)""#, #""uid":501"#,
  ]
  if let size {
    fields.append(#""size":\#(size)"#)
  }
  if let mtime {
    fields.append(#""mtime":"\#(mtime)""#)
  }
  fields += [#""message_type":"node""#, #""struct_type":"node""#]
  return "{" + fields.joined(separator: ",") + "}"
}

private func listing(_ lines: [String]) -> Data {
  Data((lines.joined(separator: "\n") + "\n").utf8)
}

@Test func parseKeepsTheDirectoryChildrenWithTheirDetails() throws {
  let entries = try SnapshotListing.parse(
    listing([
      snapshotLine,
      node("Docs", "dir", "/Users/x/Docs", mtime: "2026-11-24T13:24:46.198219245-05:00"),
      node("a.txt", "file", "/Users/x/Docs/a.txt", size: 2, mtime: "2026-11-24T13:24:46.191498575-05:00"),
      node("link", "symlink", "/Users/x/Docs/link", mtime: "2026-11-24T13:24:46Z"),
      node("sub", "dir", "/Users/x/Docs/sub", mtime: "2026-11-24T13:24:46.191554368-05:00"),
      node("pipe", "fifo", "/Users/x/Docs/pipe"),
    ]), directory: "/Users/x/Docs")
  #expect(entries.map(\.name) == ["sub", "a.txt", "link", "pipe"])
  #expect(
    entries.map(\.path) == ["/Users/x/Docs/sub", "/Users/x/Docs/a.txt", "/Users/x/Docs/link", "/Users/x/Docs/pipe"])
  #expect(entries.map(\.kind) == [.directory, .file, .symlink, .other])
  #expect(entries.map(\.size) == [nil, 2, nil, nil])
  #expect(
    entries.map { $0.modified.map { ($0.timeIntervalSince1970 * 1000).rounded() } } == [
      1_795_544_686_191, 1_795_544_686_191, 1_795_526_686_000, nil,
    ])
}

@Test func parseListsTheTopOfTheSnapshotTree() throws {
  let entries = try SnapshotListing.parse(
    listing([snapshotLine, node("Users", "dir", "/Users"), node("root.txt", "file", "/root.txt", size: 1)]),
    directory: "/")
  #expect(entries.map(\.path) == ["/Users", "/root.txt"])
}

@Test func parseIgnoresBlankLinesAndEntriesOutsideTheDirectory() throws {
  let entries = try SnapshotListing.parse(
    Data((snapshotLine + "\n\n" + node("deep", "file", "/Users/x/Docs/sub/deep") + "\n  \n").utf8),
    directory: "/Users/x/Docs")
  #expect(entries.isEmpty)
}

@Test func parseRejectsLinesThatAreNotJSON() {
  #expect(throws: SnapshotListingError(line: "Fatal: oops")) {
    _ = try SnapshotListing.parse(listing([snapshotLine, "Fatal: oops"]), directory: "/")
  }
}

@Test func sortedPutsFoldersFirstThenNamesInFinderOrder() {
  let entries = ["b10.txt", "B2.txt", "a.txt", "Zeta", "alpha"].map { name in
    SnapshotEntry(
      name: name, path: "/d/" + name, kind: name.contains(".") ? .file : .directory)
  }
  #expect(SnapshotListing.sorted(entries).map(\.name) == ["alpha", "Zeta", "a.txt", "B2.txt", "b10.txt"])
}

@Test func rootsAreTheBackedUpFoldersNamedLikeTheirRestore() {
  let roots = SnapshotListing.roots(of: ["/Users/x/Pictures", "/", "/Users/x/Documents"])
  #expect(
    roots == [
      SnapshotEntry(name: "Documents", path: "/Users/x/Documents", kind: .directory),
      SnapshotEntry(name: "Macintosh HD", path: "/", kind: .directory),
      SnapshotEntry(name: "Pictures", path: "/Users/x/Pictures", kind: .directory),
    ])
}

@Test(
  arguments: [
    ("/", nil), ("/Users", "/"), ("/Users/x/Docs", "/Users/x"), ("relative", nil),
    ("/Users/x/\u{301}Docs", "/Users/x"), ("/\u{301}Users", "/"),
  ] as [(String, String?)])
func parentPath(_ path: String, _ parent: String?) {
  #expect(SnapshotEntry(name: "n", path: path, kind: .file).parentPath == parent)
}

@Test func aChildNameStartingWithACombiningMarkIsListed() throws {
  let line = #"{"name":"\#u{301}a","type":"file","path":"/d/\#u{301}a","message_type":"node"}"#
  let entries = try SnapshotListing.parse(Data(line.utf8), directory: "/d")
  #expect(entries.map(\.name) == ["\u{301}a"])
}
