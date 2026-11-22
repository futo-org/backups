import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class Updater {
  let isAvailable: Bool
  private(set) var canCheckForUpdates: Bool
  var automaticallyChecksForUpdates: Bool {
    get { controller?.updater.automaticallyChecksForUpdates ?? false }
    set { controller?.updater.automaticallyChecksForUpdates = newValue }
  }

  private var controller: SPUStandardUpdaterController?
  private var observation: NSKeyValueObservation?

  init() {
    let feedURL = Bundle.main.infoDictionary?["SUFeedURL"] as? String
    let publicEDKey = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String
    isAvailable = (feedURL?.isEmpty == false) && (publicEDKey?.isEmpty == false)
    canCheckForUpdates = false
    if isAvailable {
      let controller = SPUStandardUpdaterController(
        startingUpdater: isAvailable, updaterDelegate: nil, userDriverDelegate: nil)
      self.controller = controller
      observation = controller.updater.observe(
        \.canCheckForUpdates, options: [.initial, .new]
      ) { [weak self] _, change in
        let canCheck = change.newValue ?? false
        Task { @MainActor [weak self] in self?.canCheckForUpdates = canCheck }
      }
    }
  }

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}
