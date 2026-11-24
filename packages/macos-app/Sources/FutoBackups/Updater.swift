import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class Updater {
  let isAvailable: Bool
  private(set) var canCheckForUpdates: Bool
  var automaticallyChecksForUpdates: Bool {
    didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
  }

  private var controller: SPUStandardUpdaterController?
  private var observation: NSKeyValueObservation?
  private var started: Bool

  init(startingUpdater: Bool) {
    let feedURL = Bundle.main.infoDictionary?["SUFeedURL"] as? String
    let publicEDKey = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String
    isAvailable = (feedURL?.isEmpty == false) && (publicEDKey?.isEmpty == false)
    canCheckForUpdates = false
    automaticallyChecksForUpdates = false
    started = startingUpdater
    if isAvailable {
      let controller = SPUStandardUpdaterController(
        startingUpdater: startingUpdater, updaterDelegate: nil, userDriverDelegate: nil)
      self.controller = controller
      automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
      observation = controller.updater.observe(
        \.canCheckForUpdates, options: [.initial, .new]
      ) { [weak self] _, change in
        let canCheck = change.newValue ?? false
        Task { @MainActor [weak self] in self?.canCheckForUpdates = canCheck }
      }
    }
  }

  func start() {
    guard !started, let controller else { return }
    started = true
    controller.startUpdater()
  }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}
