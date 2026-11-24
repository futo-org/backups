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
  private let relaunchDelegate = RelaunchDelegate()
  private var observation: NSKeyValueObservation?

  init() {
    let feedURL = Bundle.main.infoDictionary?["SUFeedURL"] as? String
    let publicEDKey = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String
    isAvailable = (feedURL?.isEmpty == false) && (publicEDKey?.isEmpty == false)
    canCheckForUpdates = false
    automaticallyChecksForUpdates = false
    if isAvailable {
      let controller = SPUStandardUpdaterController(
        startingUpdater: isAvailable, updaterDelegate: relaunchDelegate, userDriverDelegate: nil)
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

  func checkForUpdates() {
    controller?.checkForUpdates(nil)
  }
}

private final class RelaunchDelegate: NSObject, SPUUpdaterDelegate {
  func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
    MainActor.assumeIsolated { MenuBarResidency.shared.updateWillRelaunch() }
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    MainActor.assumeIsolated { MenuBarResidency.shared.updateCycleEnded() }
  }

  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
    MainActor.assumeIsolated { MenuBarResidency.shared.updateCycleEnded() }
  }
}
