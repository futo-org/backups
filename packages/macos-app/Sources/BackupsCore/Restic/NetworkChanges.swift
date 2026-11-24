import Foundation
import Network

public struct NetworkPath: Equatable, Sendable {
  public var isSatisfied: Bool
  public var interfaces: [String]
  public var gateways: Set<String>

  public init(isSatisfied: Bool, interfaces: [String], gateways: Set<String> = []) {
    self.isSatisfied = isSatisfied
    self.interfaces = interfaces
    self.gateways = gateways
  }

  public func invalidatesConnections(since previous: NetworkPath) -> Bool {
    isSatisfied
      && (!previous.isSatisfied || interfaces != previous.interfaces || gateways != previous.gateways)
  }
}

public enum NetworkChanges {
  public static let debounce = Duration.seconds(1)

  public static func live() -> AsyncStream<Void> {
    changes(in: systemPaths(), debounce: debounce, sleep: { try await Task.sleep(for: $0) })
  }

  public static func systemPaths() -> AsyncStream<NetworkPath> {
    let (stream, continuation) = AsyncStream<NetworkPath>.makeStream(bufferingPolicy: .bufferingNewest(8))
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { path in
      continuation.yield(
        NetworkPath(
          isSatisfied: path.status == .satisfied, interfaces: path.availableInterfaces.map(\.name),
          gateways: Set(path.gateways.map { "\($0)" })))
    }
    continuation.onTermination = { _ in monitor.cancel() }
    monitor.start(queue: DispatchQueue(label: "org.futo.backups.network-path"))
    return stream
  }

  public static func changes(
    in paths: AsyncStream<NetworkPath>, debounce: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void
  ) -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let watcher = Task {
      var previous: NetworkPath?
      var pending: Task<Void, Never>?
      for await path in paths {
        defer { previous = path }
        if !path.isSatisfied {
          pending?.cancel()
          pending = nil
          continue
        }
        guard let previous, path.invalidatesConnections(since: previous) else { continue }
        pending?.cancel()
        pending = Task {
          do {
            try await sleep(debounce)
          } catch {
            return
          }
          guard !Task.isCancelled else { return }
          continuation.yield()
        }
      }
      pending?.cancel()
      continuation.finish()
    }
    continuation.onTermination = { _ in watcher.cancel() }
    return stream
  }
}
