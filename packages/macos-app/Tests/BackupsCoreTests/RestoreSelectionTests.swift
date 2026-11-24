import Testing

@testable import BackupsCore

private let documents = SnapshotEntry(name: "Documents", path: "/Users/x/Documents", kind: .directory)
private let report = SnapshotEntry(name: "report.pdf", path: "/Users/x/Documents/report.pdf", kind: .file)
private let nested = SnapshotEntry(name: "notes.txt", path: "/Users/x/Documents/Work/notes.txt", kind: .file)
private let lookalike = SnapshotEntry(name: "Documents 2", path: "/Users/x/Documents 2", kind: .directory)
private let volume = SnapshotEntry(name: "Macintosh HD", path: "/", kind: .directory)

@Test func toggleAddsAndRemovesEntriesInPickOrder() {
  var selection = RestoreSelection()
  selection.toggle(report)
  selection.toggle(lookalike)
  #expect(selection.entries == [report, lookalike])
  #expect(selection.count == 2)
  selection.toggle(report)
  #expect(selection.entries == [lookalike])
  #expect(!selection.contains(report))
}

@Test func pickingAFolderReplacesWhatWasPickedInsideIt() {
  var selection = RestoreSelection()
  selection.toggle(report)
  selection.toggle(nested)
  selection.toggle(lookalike)
  selection.toggle(documents)
  #expect(selection.entries == [lookalike, documents])
}

@Test func entriesInsideAPickedFolderAreIncludedButCannotBeToggled() {
  var selection = RestoreSelection()
  selection.toggle(documents)
  #expect(selection.isCoveredByFolder(nested))
  #expect(selection.isIncluded(nested))
  #expect(!selection.contains(nested))
  #expect(!selection.isCoveredByFolder(lookalike))
  #expect(!selection.isCoveredByFolder(documents))
  selection.toggle(nested)
  #expect(selection.entries == [documents])
}

@Test func theWholeVolumeCoversEverything() {
  var selection = RestoreSelection()
  selection.toggle(report)
  selection.toggle(volume)
  #expect(selection.entries == [volume])
  #expect(selection.isCoveredByFolder(lookalike))
}

@Test func aFileNeverCoversAnything() {
  var selection = RestoreSelection()
  let fileNamedLikeAFolder = SnapshotEntry(name: "Documents", path: "/Users/x/Documents", kind: .file)
  selection.toggle(fileNamedLikeAFolder)
  #expect(!selection.isCoveredByFolder(report))
}

@Test func removeAllClearsTheSelection() {
  var selection = RestoreSelection()
  selection.toggle(report)
  selection.removeAll()
  #expect(selection.isEmpty)
}
