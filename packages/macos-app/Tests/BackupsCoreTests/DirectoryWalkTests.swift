import Foundation
import Testing

@testable import BackupsCore

private func file(_ name: String, _ bytes: Int64) -> DirectoryEntry {
  DirectoryEntry(name: name, kind: .file(bytes: bytes, cloudOnly: false))
}

@Test func aListingCutShortKeepsItsBytesButMarksTheWalkIncomplete() {
  let state = WalkState()
  state.add(DirectoryListing(entries: [file("a", 3), file("b", 4)], isComplete: false), in: "/r") { _ in false }
  #expect(state.total == 7)
  #expect(!state.isComplete)
}

@Test(
  "an entry macOS couldn't describe makes the walk incomplete unless it is excluded",
  arguments: [
    ("secret", false, false),
    ("secret", true, true),
    ("", true, false),
  ])
func unreadableEntries(name: String, excluded: Bool, staysComplete: Bool) {
  let state = WalkState()
  let listing = DirectoryListing(entries: [file("a", 5), DirectoryEntry(name: name, kind: .unreadable)])
  state.add(listing, in: "/r") { $0 == "/r/secret" && excluded }
  #expect(state.total == 5)
  #expect(state.isComplete == staysComplete)
}

@Test func aCompleteListingKeepsTheWalkComplete() {
  let state = WalkState()
  state.add(DirectoryListing(entries: [file("a", 2)]), in: "/r") { _ in false }
  #expect(state.total == 2)
  #expect(state.isComplete)
}
