import BackupsCore
import Foundation
import Observation

@MainActor
@Observable
final class SnapshotBrowser {
  enum Listing: Equatable {
    case loading
    case loaded([SnapshotEntry])
    case failed(String)
  }

  let snapshot: Snapshot
  private(set) var trail: [SnapshotEntry] = []
  private(set) var listing: Listing
  var selection = RestoreSelection()

  @ObservationIgnored private let cache: SnapshotDirectoryCache
  @ObservationIgnored private let describe: (any Error) -> String
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var loadingDirectory: String?

  init(
    snapshot: Snapshot, describe: @escaping (any Error) -> String,
    load: @escaping @Sendable (String) async throws -> [SnapshotEntry]
  ) {
    self.snapshot = snapshot
    self.describe = describe
    cache = SnapshotDirectoryCache(load: load)
    listing = .loaded(SnapshotListing.roots(of: snapshot.paths))
  }

  var isAtRoot: Bool { trail.isEmpty }

  func open(_ entry: SnapshotEntry) {
    guard entry.isDirectory else { return }
    trail.append(entry)
    showCurrent()
  }

  func goBack() {
    guard !trail.isEmpty else { return }
    trail.removeLast()
    showCurrent()
  }

  func goTo(depth: Int) {
    guard depth < trail.count else { return }
    trail.removeLast(trail.count - depth)
    showCurrent()
  }

  func retry() {
    showCurrent()
  }

  func close() {
    loadTask?.cancel()
    cache.cancelAll()
  }

  private func showCurrent() {
    loadTask?.cancel()
    if let leaving = loadingDirectory, leaving != trail.last?.path {
      cache.cancel(leaving)
    }
    loadingDirectory = nil
    guard let directory = trail.last?.path else {
      listing = .loaded(SnapshotListing.roots(of: snapshot.paths))
      return
    }
    if let cached = cache.cached(directory) {
      listing = .loaded(cached)
      return
    }
    listing = .loading
    loadingDirectory = directory
    let cache = cache
    loadTask = Task {
      do {
        let entries = try await cache.entries(in: directory)
        show(.loaded(entries), for: directory)
      } catch is CancellationError {
        return
      } catch {
        show(.failed(describe(error)), for: directory)
      }
    }
  }

  private func show(_ result: Listing, for directory: String) {
    guard !Task.isCancelled, trail.last?.path == directory else { return }
    loadingDirectory = nil
    listing = result
  }
}

extension SnapshotBrowser: Identifiable {}
