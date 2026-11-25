import BackupsCore
import Darwin
import Foundation
import Testing

private struct Tree {
  let root: URL

  init() throws {
    root = URL(fileURLWithPath: DataVolume.resolvedPath(FileManager.default.temporaryDirectory.path))
      .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func file(_ relative: String, bytes: Int) throws {
    let url = root.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: bytes).write(to: url)
  }

  func path(_ relative: String) -> String {
    root.appendingPathComponent(relative).path
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

@Test func measuresNestedFilesIncludingHiddenOnes() throws {
  let tree = try Tree()
  defer { tree.remove() }
  try tree.file("a.txt", bytes: 100)
  try tree.file("nested/b.bin", bytes: 2_000)
  try tree.file("nested/deeper/.hidden", bytes: 30)
  try tree.file("Photos Library.photoslibrary/originals/c.heic", bytes: 400)
  #expect(FolderSizer(excludes: []).measure(tree.root.path) == .bytes(2_530))
}

@Test func emptyDirectoryMeasuresZero() throws {
  let tree = try Tree()
  defer { tree.remove() }
  #expect(FolderSizer(excludes: []).measure(tree.root.path) == .bytes(0))
}

@Test func skipsExcludedDirectoriesAndGlobbedNames() throws {
  let tree = try Tree()
  defer { tree.remove() }
  try tree.file("keep.txt", bytes: 10)
  try tree.file("Library/Caches/big", bytes: 5_000)
  try tree.file("Library/Containers/app/Data/Library/Caches/blob", bytes: 7_000)
  try tree.file("Library/Containers/app/Data/Documents/doc", bytes: 20)
  try tree.file("Code/web/node_modules/pkg/index.js", bytes: 9_000)
  try tree.file("Code/web/src/index.js", bytes: 300)
  try tree.file("Code/.DS_Store", bytes: 4_000)
  try tree.file(".Trash/old", bytes: 8_000)
  let excludes = [
    tree.path("Library/Caches"),
    tree.path("Library/Containers/*/Data/Library/Caches"),
    tree.path(".Trash"),
    "**/node_modules",
    "**/.DS_Store",
  ]
  #expect(FolderSizer(excludes: excludes).measure(tree.root.path) == .bytes(330))
}

@Test(
  "exclude patterns",
  arguments: [
    ("/Users/a/Library/Caches", "/Users/a/Library/Caches", true),
    ("/Users/a/Library/Caches", "/Users/a/Library/CachesOld", false),
    ("/Users/a/Library/Containers/*/Data/Library/Caches", "/Users/a/Library/Containers/x/Data/Library/Caches", true),
    ("/Users/a/Library/Containers/*/Data/Library/Caches", "/Users/a/Library/Containers/x/y/Data/Library/Caches", false),
    ("**/node_modules", "/Users/a/code/node_modules", true),
    ("**/node_modules", "/Users/a/code/node_modules_old", false),
    ("**/.DS_Store", "/Users/a/.DS_Store", true),
    ("*.tmp", "/Users/a/file.tmp", true),
  ])
func excludePatterns(pattern: String, path: String, expected: Bool) {
  #expect(FolderSizer(excludes: [pattern]).isExcluded(path) == expected)
}

@Test func missingOrFilePathIsUnavailable() throws {
  let tree = try Tree()
  defer { tree.remove() }
  try tree.file("file", bytes: 3)
  let sizer = FolderSizer(excludes: [])
  #expect(sizer.measure(tree.path("missing")) == .unavailable)
  #expect(sizer.measure(tree.path("file")) == .unavailable)
}

@Test func unreadableRootIsUnavailableAndUnreadableChildMakesTheSizeALowerBound() throws {
  let tree = try Tree()
  defer {
    chmod(tree.path("locked"), 0o700)
    chmod(tree.path("open/private"), 0o700)
    tree.remove()
  }
  try tree.file("locked/a", bytes: 10)
  try tree.file("open/visible", bytes: 5)
  try tree.file("open/private/secret", bytes: 50)
  chmod(tree.path("locked"), 0)
  chmod(tree.path("open/private"), 0)
  let sizer = FolderSizer(excludes: [])
  #expect(sizer.measure(tree.path("locked")) == .unavailable)
  #expect(sizer.measure(tree.path("open")) == .atLeast(5))
  #expect(sizer.measure(tree.root.path) == .atLeast(5))
}

@Test func cancellationStopsTheWalk() throws {
  let tree = try Tree()
  defer { tree.remove() }
  try tree.file("a", bytes: 1)
  try tree.file("b", bytes: 1)
  #expect(FolderSizer(excludes: []).measure(tree.root.path, isCancelled: { true }) == .unavailable)
}

@Test func sizeRunsAsynchronously() async throws {
  let tree = try Tree()
  defer { tree.remove() }
  try tree.file("a", bytes: 42)
  #expect(try await FolderSizer(excludes: []).size(of: tree.root.path) == .bytes(42))
}

@Test func cancelledTaskThrows() async throws {
  let tree = try Tree()
  defer { tree.remove() }
  try tree.file("a", bytes: 42)
  let sizer = FolderSizer(excludes: [])
  let task = Task {
    withUnsafeCurrentTask { $0?.cancel() }
    return try await sizer.size(of: tree.root.path)
  }
  await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func unreadableChildThatIsExcludedKeepsTheSizeExact() throws {
  let tree = try Tree()
  defer {
    chmod(tree.path("open/private"), 0o700)
    tree.remove()
  }
  try tree.file("open/visible", bytes: 5)
  try tree.file("open/private/secret", bytes: 50)
  chmod(tree.path("open/private"), 0)
  #expect(FolderSizer(excludes: [tree.path("open/private")]).measure(tree.path("open")) == .bytes(5))
}

@Test(
  "size total summary",
  arguments: [
    (SizeTotal(bytes: 10, isCalculating: true), "Calculating"),
    (SizeTotal(isCalculating: true, isPartial: true), "Calculating"),
    (SizeTotal(isPartial: true), "Size unavailable"),
    (SizeTotal(), "Size unavailable"),
    (SizeTotal(bytes: 0), "About 0 B"),
    (SizeTotal(bytes: 12), "About 12 B"),
    (SizeTotal(bytes: 12, isPartial: true), "At least 12 B"),
  ])
func sizeTotalSummary(total: SizeTotal, expected: String) {
  #expect(total.summary { "\($0) B" } == expected)
}
