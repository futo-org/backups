import Foundation
import Observation

@MainActor
@Observable
public final class FolderSizeEstimates {
  public private(set) var sizes: [String: FolderSize] = [:]
  private let measure: @Sendable (String) async throws -> FolderSize
  private var tasks: [String: Task<Void, Never>] = [:]

  public init(measure: @escaping @Sendable (String) async throws -> FolderSize) {
    self.measure = measure
  }

  public convenience init(sizer: FolderSizer) {
    self.init(measure: { try await sizer.size(of: $0) })
  }

  public func request(_ paths: [String]) {
    for path in paths where sizes[path] == nil {
      sizes[path] = .calculating
      let measure = measure
      tasks[path] = Task {
        do {
          sizes[path] = try await measure(path)
        } catch is CancellationError {
          sizes[path] = nil
        } catch {
          sizes[path] = .unavailable
        }
        tasks[path] = nil
      }
    }
  }

  public func cancelAll() {
    for task in tasks.values {
      task.cancel()
    }
  }
}
