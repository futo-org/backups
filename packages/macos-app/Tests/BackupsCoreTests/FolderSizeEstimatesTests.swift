import BackupsCore
import Foundation
import Synchronization
import Testing

private struct Unreadable: Error {}

private final class Calls: Sendable {
  private let paths = Mutex<[String]>([])

  func record(_ path: String) {
    paths.withLock { $0.append(path) }
  }

  var all: [String] { paths.withLock { $0 } }
}

@MainActor
private func settle(_ estimates: FolderSizeEstimates, until done: (FolderSizeEstimates) -> Bool) async throws {
  for _ in 0..<2_000 where !done(estimates) {
    try await Task.sleep(for: .milliseconds(1))
  }
  #expect(done(estimates))
}

@MainActor
@Test func requestedPathsResolveToSizesOrUnavailable() async throws {
  let estimates = FolderSizeEstimates { path in
    switch path {
    case "/a": 10
    case "/b": nil
    default: throw Unreadable()
    }
  }
  estimates.request(["/a", "/b", "/c"])
  #expect(estimates.sizes["/a"] == .calculating)
  try await settle(estimates) { !$0.sizes.values.contains(.calculating) }
  #expect(estimates.sizes == ["/a": .bytes(10), "/b": .unavailable, "/c": .unavailable])
}

@MainActor
@Test func pathsAreMeasuredOnce() async throws {
  let calls = Calls()
  let estimates = FolderSizeEstimates { path in
    calls.record(path)
    return 1
  }
  estimates.request(["/a"])
  estimates.request(["/a", "/b"])
  try await settle(estimates) { $0.sizes.count == 2 && !$0.sizes.values.contains(.calculating) }
  estimates.request(["/a", "/b"])
  try await settle(estimates) { !$0.sizes.values.contains(.calculating) }
  #expect(calls.all.sorted() == ["/a", "/b"])
}

@MainActor
@Test func cancellingForgetsPendingSizesSoTheyCanBeRequestedAgain() async throws {
  let estimates = FolderSizeEstimates { _ in
    try await Task.sleep(for: .seconds(30))
    return 1
  }
  estimates.request(["/slow"])
  #expect(estimates.sizes["/slow"] == .calculating)
  estimates.cancelAll()
  try await settle(estimates) { $0.sizes["/slow"] == nil }
  estimates.request(["/slow"])
  #expect(estimates.sizes["/slow"] == .calculating)
  estimates.cancelAll()
}

@MainActor
@Test func sizerInitializerMeasuresTheFilesystem() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data(repeating: 1, count: 64).write(to: root.appendingPathComponent("file"))
  let estimates = FolderSizeEstimates(sizer: FolderSizer(excludes: []))
  estimates.request([root.path])
  try await settle(estimates) { $0.sizes[root.path] != .calculating }
  #expect(estimates.sizes[root.path] == .bytes(64))
}
