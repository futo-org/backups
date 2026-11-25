import BackupsCore
import Foundation
import Testing

private let home = "/Users/test"

private func selection(
  _ bundle: FolderBundle = .essentialsAndMedia, existing: Set<String>? = nil
) -> FolderSelection {
  FolderSelection(home: home, bundle: bundle) { path in existing?.contains(path) ?? true }
}

private func path(_ name: String) -> String {
  home + "/" + name
}

@Test(
  "bundles pre-tick their folders and never Downloads",
  arguments: [
    (FolderBundle.essentials, [path("Documents"), path("Desktop")]),
    (
      FolderBundle.essentialsAndMedia,
      [path("Documents"), path("Desktop"), path("Pictures"), path("Movies"), path("Music")]
    ),
    (FolderBundle.everything, [home]),
  ])
func bundlePaths(bundle: FolderBundle, expected: [String]) {
  let chosen = selection(bundle)
  #expect(chosen.bundle == bundle)
  #expect(chosen.paths == expected)
  #expect(!chosen.isSelected(.standard(.downloads)))
}

@Test func choicesListStandardFoldersThenHome() {
  #expect(
    selection().choices == StandardFolder.allCases.map(FolderChoice.standard) + [.home])
}

@Test func onlyExistingFoldersAreOffered() {
  let chosen = selection(.essentialsAndMedia, existing: [home, path("Documents"), path("Music")])
  #expect(chosen.choices == [.standard(.documents), .standard(.music), .home])
  #expect(chosen.paths == [path("Documents"), path("Music")])
}

@Test func homeIsNormalized() {
  let chosen = FolderSelection(home: "/Users/test/", bundle: .everything) { _ in true }
  #expect(chosen.home == home)
  #expect(chosen.paths == [home])
}

@Test func homeFolderSupersedesItsChildren() {
  var chosen = selection(.essentials)
  chosen.set(.home, selected: true)
  #expect(chosen.paths == [home])
  #expect(chosen.coveringChoice(of: .standard(.documents)) == .home)
  #expect(chosen.coveringChoice(of: .standard(.downloads)) == .home)
  #expect(chosen.coveringChoice(of: .home) == nil)
  #expect(chosen.isIncluded(.standard(.downloads)))
  #expect(!chosen.isSelected(.standard(.downloads)))
  chosen.set(.home, selected: false)
  #expect(chosen.paths == [path("Documents"), path("Desktop")])
  #expect(!chosen.isIncluded(.standard(.downloads)))
}

@Test func togglingFineTunesTheBundle() {
  var chosen = selection(.essentials)
  chosen.set(.standard(.downloads), selected: true)
  chosen.set(.standard(.desktop), selected: false)
  #expect(chosen.paths == [path("Documents"), path("Downloads")])
}

@Test func togglingAChoiceThatIsNotOfferedIsIgnored() {
  var chosen = selection(.essentials, existing: [home, path("Documents")])
  chosen.set(.standard(.movies), selected: true)
  #expect(chosen.paths == [path("Documents")])
}

@Test func otherFoldersJoinTheListAndSurviveBundleChanges() {
  var chosen = selection(.essentials)
  chosen.addOthers(["/Volumes/Work/Projects", "/Volumes/Work/Projects/", path("Documents")])
  #expect(chosen.choices.last == .other("/Volumes/Work/Projects"))
  #expect(chosen.choices.count == StandardFolder.allCases.count + 2)
  #expect(chosen.paths == [path("Documents"), path("Desktop"), "/Volumes/Work/Projects"])
  chosen.apply(.everything)
  #expect(chosen.paths == [home, "/Volumes/Work/Projects"])
}

@Test func otherFolderInsideHomeIsCoveredByHome() {
  var chosen = selection(.everything)
  chosen.addOthers([path("Code")])
  #expect(chosen.coveringChoice(of: .other(path("Code"))) == .home)
  #expect(chosen.paths == [home])
}

@Test func otherFolderInsideASelectedFolderIsCovered() {
  var chosen = selection(.essentials)
  chosen.addOthers([path("Documents/Taxes")])
  #expect(chosen.paths == [path("Documents"), path("Desktop")])
  chosen.set(.standard(.documents), selected: false)
  #expect(chosen.paths == [path("Desktop"), path("Documents/Taxes")])
}

@Test func siblingWithSharedPrefixIsNotCovered() {
  var chosen = selection(.essentials)
  chosen.addOthers([path("Documents Old")])
  #expect(chosen.paths == [path("Documents"), path("Desktop"), path("Documents Old")])
}

@Test func pickingHomeInThePanelSelectsTheHomeChoice() {
  var chosen = selection(.essentials)
  chosen.addOthers([home])
  #expect(chosen.choices.count == StandardFolder.allCases.count + 1)
  #expect(chosen.paths == [home])
}

@Test func continueRequiresASelection() {
  var chosen = selection(.essentials)
  #expect(chosen.canContinue)
  chosen.set(.standard(.documents), selected: false)
  chosen.set(.standard(.desktop), selected: false)
  #expect(!chosen.canContinue)
  #expect(chosen.paths.isEmpty)
}

@Test func applyingReturnsACopyWithTheBundle() {
  let chosen = selection(.essentials)
  let everything = chosen.applying(.everything)
  #expect(chosen.paths == [path("Documents"), path("Desktop")])
  #expect(everything.paths == [home])
}

@Test func totalAddsSelectedPathsAndFlagsPendingAndUnavailable() {
  let chosen = selection(.essentialsAndMedia)
  let sizes: [String: FolderSize] = [
    path("Documents"): .bytes(100),
    path("Desktop"): .bytes(20),
    path("Pictures"): .calculating,
    path("Movies"): .unavailable,
    path("Music"): .bytes(3),
    path("Downloads"): .bytes(1_000),
  ]
  #expect(
    chosen.total { sizes[$0] ?? .calculating }
      == SizeTotal(bytes: 123, isCalculating: true, isPartial: true))
  #expect(selection(.essentials).total { sizes[$0] ?? .calculating } == SizeTotal(bytes: 120))
}

@Test func totalCountsFoldersInsideAnotherSelectedFolderOnce() {
  var chosen = selection(.essentials)
  chosen.set(.home, selected: true)
  chosen.addOthers(["/Volumes/Work"])
  let sizes: [String: FolderSize] = [
    home: .bytes(500), path("Documents"): .bytes(100), path("Desktop"): .bytes(20), "/Volumes/Work": .bytes(7),
  ]
  #expect(chosen.total { sizes[$0] ?? .calculating } == SizeTotal(bytes: 507))
}

@Test func totalIsALowerBoundWhenAFolderWasOnlyPartlyRead() {
  let chosen = selection(.essentials)
  let sizes: [String: FolderSize] = [path("Documents"): .atLeast(100), path("Desktop"): .bytes(20)]
  #expect(chosen.total { sizes[$0] ?? .calculating } == SizeTotal(bytes: 120, isPartial: true))
}

@Test func totalHasNoBytesWhenNoFolderCouldBeMeasured() {
  let chosen = selection(.essentials)
  #expect(chosen.total { _ in .unavailable } == SizeTotal(isPartial: true))
  #expect(chosen.total { _ in .bytes(0) } == SizeTotal(bytes: 0))
}

@Test(
  "only home, Documents, Desktop and Downloads prompt without Full Disk Access",
  arguments: [
    (FolderChoice.home, true),
    (.standard(.documents), true),
    (.standard(.desktop), true),
    (.standard(.downloads), true),
    (.standard(.pictures), false),
    (.standard(.movies), false),
    (.standard(.music), false),
    (.other("/Volumes/Work"), false),
  ])
func promptsWithoutFullDiskAccess(choice: FolderChoice, expected: Bool) {
  #expect(choice.promptsWithoutFullDiskAccess == expected)
}

@Test func withoutFullDiskAccessOnlyIncludedProtectedFoldersAreMeasured() {
  var chosen = selection(.essentials)
  #expect(
    chosen.pathsToMeasure(hasFullDiskAccess: false)
      == [path("Documents"), path("Desktop"), path("Pictures"), path("Movies"), path("Music")])
  #expect(chosen.pathsToMeasure(hasFullDiskAccess: true) == chosen.choices.map { chosen.path(of: $0) })
  chosen.set(.home, selected: true)
  #expect(chosen.pathsToMeasure(hasFullDiskAccess: false) == chosen.choices.map { chosen.path(of: $0) })
}

@Test func choicePathsResolveAgainstHome() {
  #expect(FolderChoice.home.path(home: home) == home)
  #expect(FolderChoice.standard(.pictures).path(home: home) == path("Pictures"))
  #expect(FolderChoice.other("/Volumes/X").path(home: home) == "/Volumes/X")
}

@Test func defaultDirectoryCheckRequiresAnExistingDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("file")
  try Data().write(to: file)
  #expect(FolderSelection.isDirectory(root.path))
  #expect(!FolderSelection.isDirectory(file.path))
  #expect(!FolderSelection.isDirectory(root.appendingPathComponent("missing").path))
}
