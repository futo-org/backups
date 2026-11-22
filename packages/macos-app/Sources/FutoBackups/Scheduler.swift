import AppKit
import Foundation

@MainActor
final class Scheduler {
  private let model: AppModel
  private var loop: Task<Void, Never>?
  private var wakeObserver: (any NSObjectProtocol)?

  init(model: AppModel) {
    self.model = model
  }

  func start() {
    guard loop == nil else { return }
    loop = Task {
      while true {
        do {
          try await Task.sleep(for: .seconds(60))
        } catch {
          return
        }
        self.model.tick()
      }
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.model.tick()
      }
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
    if let wakeObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
      self.wakeObserver = nil
    }
  }
}
