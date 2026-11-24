import Darwin
import Foundation
import Testing

@testable import BackupsCore

private let dataless = FileStatus.datalessFlag

final class FakeFileTree: FileTree, @unchecked Sendable {
  private let lock = NSLock()
  private let statuses: [String: FileStatus]
  private var listed: [String] = []
  private let gate: DispatchSemaphore?
  private var entered = false

  init(_ statuses: [String: FileStatus], gated: Bool = false) {
    var all = statuses
    for path in statuses.keys {
      var parent = (path as NSString).deletingLastPathComponent
      while parent != "/" && all[parent] == nil {
        all[parent] = FileStatus(kind: .directory)
        parent = (parent as NSString).deletingLastPathComponent
      }
    }
    all["/"] = all["/"] ?? FileStatus(kind: .directory)
    self.statuses = all
    self.gate = gated ? DispatchSemaphore(value: 0) : nil
  }

  var listedDirectories: [String] {
    lock.withLock { listed }
  }

  var hasEntered: Bool {
    lock.withLock { entered }
  }

  func release() {
    gate?.signal()
  }

  func status(at path: String) -> FileStatus? {
    statuses[path]
  }

  func entries(in directory: String) -> [FileTreeEntry]? {
    let first = lock.withLock { () -> Bool in
      listed.append(directory)
      defer { entered = true }
      return !entered
    }
    if first {
      gate?.wait()
    }
    guard statuses[directory]?.kind == .directory else { return nil }
    let prefix = directory == "/" ? "/" : directory + "/"
    return
      statuses
      .filter { $0.key.hasPrefix(prefix) && $0.key != "/" && !$0.key.dropFirst(prefix.count).contains("/") }
      .map { FileTreeEntry(name: String($0.key.dropFirst(prefix.count)), status: $0.value) }
      .sorted { $0.name < $1.name }
  }
}

private func file(_ size: Int64, cloudOnly: Bool = false, device: Int32 = 1) -> FileStatus {
  FileStatus(kind: .regular, flags: cloudOnly ? dataless | 0x20 : 0x20, size: size, device: device)
}

private func folder(cloudOnly: Bool = false, device: Int32 = 1) -> FileStatus {
  FileStatus(kind: .directory, flags: cloudOnly ? dataless : 0, device: device)
}

@Test func countsCloudOnlyFilesAndTheirLogicalSize() async throws {
  let tree = FakeFileTree([
    "/Users/a/Documents/ws.pptx": file(3_000, cloudOnly: true),
    "/Users/a/Documents/notes.txt": file(10),
    "/Users/a/Documents/Deep/Deeper/movie.mov": file(5_000_000, cloudOnly: true),
    "/Users/a/Documents/Deep/local.mov": file(9_000_000),
  ])
  let skip = try #require(await CloudOnlyScanner(tree: tree).scan(folders: ["/Users/a/Documents"], excludes: []))
  #expect(skip.count == 2)
  #expect(skip.bytes == 5_003_000)
  #expect(skip.sample == ["/Users/a/Documents/Deep/Deeper/movie.mov", "/Users/a/Documents/ws.pptx"])
}

@Test func excludedDirectoriesAreNotListedAndExcludedFilesNotCounted() throws {
  let tree = FakeFileTree([
    "/Users/a/Documents/node_modules/pkg/big.bin": file(1, cloudOnly: true),
    "/Users/a/Documents/Project/node_modules/pkg/big.bin": file(1, cloudOnly: true),
    "/Users/a/Documents/Library/Caches/blob": file(1, cloudOnly: true),
    "/Users/a/Documents/Kept/.DS_Store": file(1, cloudOnly: true),
    "/Users/a/Documents/Kept/report.pdf": file(7, cloudOnly: true),
  ])
  let skip = try #require(
    CloudOnlyScanner(tree: tree).walk(
      folders: ["/Users/a/Documents"],
      excludes: ["**/node_modules", "**/.DS_Store", "/Users/a/Documents/Library/Caches"],
      isCancelled: { false }))
  #expect(skip.count == 1)
  #expect(skip.sample == ["/Users/a/Documents/Kept/report.pdf"])
  #expect(!tree.listedDirectories.contains { $0.contains("node_modules") || $0.hasSuffix("Caches") })
}

@Test func anExcludedFolderIsNotScannedAtAll() throws {
  let tree = FakeFileTree(["/Users/a/Library/Caches/blob": file(1, cloudOnly: true)])
  let skip = try #require(
    CloudOnlyScanner(tree: tree).walk(
      folders: ["/Users/a/Library/Caches/"], excludes: ["/Users/a/Library/Caches"], isCancelled: { false }))
  #expect(skip == CloudOnlySkip())
  #expect(tree.listedDirectories.isEmpty)
}

@Test func symlinksAreNeverFollowed() throws {
  let tree = FakeFileTree([
    "/Users/a/Documents/link": FileStatus(kind: .symbolicLink, flags: dataless),
    "/Users/a/Documents/dir-link": FileStatus(kind: .symbolicLink),
    "/Users/a/iCloud/remote.key": file(1, cloudOnly: true),
  ])
  let skip = try #require(
    CloudOnlyScanner(tree: tree).walk(folders: ["/Users/a/Documents"], excludes: [], isCancelled: { false }))
  #expect(skip.count == 0)
  #expect(tree.listedDirectories == ["/Users/a/Documents"])
}

@Test func otherVolumesAreSkippedUnlessTheFolderIsOnOne() throws {
  let tree = FakeFileTree([
    "/Users/a/Documents/Mounted": folder(device: 2),
    "/Users/a/Documents/Mounted/remote.bin": file(1, cloudOnly: true, device: 2),
    "/Volumes/Ext": folder(device: 2),
    "/Volumes/Ext/Photos": folder(device: 2),
    "/Volumes/Ext/Photos/remote.raw": file(4, cloudOnly: true, device: 2),
  ])
  let skip = try #require(
    CloudOnlyScanner(tree: tree).walk(
      folders: ["/Users/a/Documents", "/Volumes/Ext"], excludes: [], isCancelled: { false }))
  #expect(skip.sample == ["/Volumes/Ext/Photos/remote.raw"])
  #expect(!tree.listedDirectories.contains("/Users/a/Documents/Mounted"))
}

@Test func cloudOnlyFoldersAreCountedWithoutBeingListed() throws {
  let tree = FakeFileTree([
    "/Users/a/Desktop": folder(cloudOnly: true),
    "/Users/a/Documents/Old": folder(cloudOnly: true),
    "/Users/a/Documents/Old/inside.txt": file(5, cloudOnly: true),
  ])
  let scanner = CloudOnlyScanner(tree: tree)
  #expect(scanner.isCloudOnly("/Users/a/Desktop"))
  #expect(!scanner.isCloudOnly("/Users/a/Documents"))
  #expect(!scanner.isCloudOnly("/missing"))
  let skip = try #require(
    scanner.walk(folders: ["/Users/a/Desktop", "/Users/a/Documents"], excludes: [], isCancelled: { false }))
  #expect(skip.count == 2)
  #expect(skip.bytes == 0)
  #expect(skip.sample == ["/Users/a/Desktop/", "/Users/a/Documents/Old/"])
  #expect(tree.listedDirectories == ["/Users/a/Documents"])
}

@Test func aCloudOnlyFileSelectedDirectlyIsCounted() throws {
  let tree = FakeFileTree(["/Users/a/big.zip": file(42, cloudOnly: true), "/Users/a/small.txt": file(1)])
  let skip = try #require(
    CloudOnlyScanner(tree: tree).walk(
      folders: ["/Users/a/big.zip", "/Users/a/small.txt", "/missing"], excludes: [], isCancelled: { false }))
  #expect(skip == CloudOnlySkip(count: 1, bytes: 42, sample: ["/Users/a/big.zip"]))
}

@Test func sampleIsCappedButCountAndSizeCoverEverything() throws {
  var statuses: [String: FileStatus] = [:]
  for index in 0..<25 {
    statuses["/r/f\(index)"] = file(2, cloudOnly: true)
  }
  let skip = try #require(
    CloudOnlyScanner(tree: FakeFileTree(statuses), sampleLimit: 10).walk(
      folders: ["/r"], excludes: [], isCancelled: { false }))
  #expect(skip.count == 25)
  #expect(skip.bytes == 50)
  #expect(skip.sample.count == 10)
  #expect(skip.sample == skip.sample.sorted())
}

@Test func walkingTheRootJoinsPathsWithoutDoubleSlashes() throws {
  let tree = FakeFileTree(["/top.bin": file(1, cloudOnly: true), "/sub/inner.bin": file(1, cloudOnly: true)])
  let skip = try #require(CloudOnlyScanner(tree: tree).walk(folders: ["/"], excludes: [], isCancelled: { false }))
  #expect(skip.sample == ["/sub/inner.bin", "/top.bin"])
}

@Test func walkStopsWhenCancelled() {
  let tree = FakeFileTree(["/r/a/x": file(1, cloudOnly: true), "/r/b/y": file(1, cloudOnly: true)])
  let checks = Counter()
  let skip = CloudOnlyScanner(tree: tree).walk(folders: ["/r"], excludes: []) {
    checks.increment()
    return checks.value > 1
  }
  #expect(skip == nil)
  #expect(tree.listedDirectories == ["/r"])
}

@Test func cancellingTheScanTaskStopsTheWalk() async throws {
  let tree = FakeFileTree(["/r/a/x": file(1, cloudOnly: true)], gated: true)
  let task = Task { await CloudOnlyScanner(tree: tree).scan(folders: ["/r"], excludes: []) }
  while !tree.hasEntered {
    try await Task.sleep(for: .milliseconds(5))
  }
  task.cancel()
  tree.release()
  #expect(await task.value == nil)
  #expect(tree.listedDirectories == ["/r"])
}

@Test(
  arguments: [
    (Int64(0), "0"), (99_999_999, "<100MB"), (100_000_000, "<1GB"), (5_000_000_000, "<10GB"),
    (50_000_000_000, "<100GB"), (100_000_000_000, ">=100GB"),
  ])
func telemetrySizeBucket(bytes: Int64, expected: String) {
  #expect(CloudOnlySkip(count: 1, bytes: bytes).telemetrySizeBucket == expected)
}

@Test func localFileTreeReportsKindsSizesAndDeviceWithoutFollowingSymlinks() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-only-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data(count: 1234).write(to: root.appendingPathComponent("file.bin"))
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("sub"))
  let tree = LocalFileTree()
  let rootStatus = try #require(tree.status(at: root.path))
  #expect(rootStatus.kind == .directory)
  #expect(!rootStatus.isDataless)
  #expect(tree.status(at: root.appendingPathComponent("missing").path) == nil)
  #expect(tree.status(at: root.appendingPathComponent("link").path)?.kind == .symbolicLink)
  #expect(tree.entries(in: root.appendingPathComponent("link").path) == nil)
  let entries = try #require(tree.entries(in: root.path)).sorted { $0.name < $1.name }
  #expect(entries.map(\.name) == ["file.bin", "link", "sub"])
  #expect(entries.map(\.status.kind) == [.regular, .symbolicLink, .directory])
  #expect(entries[0].status.size == 1234)
  #expect(entries.allSatisfy { $0.status.device == rootStatus.device && !$0.status.isDataless })
  #expect(CloudOnlyScanner().walk(folders: [root.path], excludes: [], isCancelled: { false }) == CloudOnlySkip())
}
