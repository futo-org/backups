import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class Updater {
  let isAvailable: Bool
  var canCheckForUpdates: Bool { controller != nil && (!started || sparkleCanCheckForUpdates) }
  var automaticallyChecksForUpdates: Bool {
    didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
  }

  private var controller: SPUStandardUpdaterController?
  private let backgroundCheckGate: BackgroundCheckGate
  private var observation: NSKeyValueObservation?
  private var started: Bool
  private var sparkleCanCheckForUpdates = false

  init(startingUpdater: Bool) {
    let feedURL = Bundle.main.infoDictionary?["SUFeedURL"] as? String
    let publicEDKey = Bundle.main.infoDictionary?["SUPublicEDKey"] as? String
    isAvailable = (feedURL?.isEmpty == false) && (publicEDKey?.isEmpty == false)
    automaticallyChecksForUpdates = false
    started = startingUpdater
    backgroundCheckGate = BackgroundCheckGate(holdingBackgroundChecks: !startingUpdater)
    if isAvailable {
      let controller = SPUStandardUpdaterController(
        startingUpdater: startingUpdater, updaterDelegate: backgroundCheckGate, userDriverDelegate: nil)
      self.controller = controller
      automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
      observation = controller.updater.observe(
        \.canCheckForUpdates, options: [.initial, .new]
      ) { [weak self] _, change in
        let canCheck = change.newValue ?? false
        Task { @MainActor [weak self] in self?.sparkleCanCheckForUpdates = canCheck }
      }
    }
  }

  func start() {
    guard let controller else { return }
    backgroundCheckGate.holdingBackgroundChecks = false
    startSparkle(controller)
  }

  func checkForUpdates() {
    guard let controller else { return }
    startSparkle(controller)
    controller.checkForUpdates(nil)
  }

  private func startSparkle(_ controller: SPUStandardUpdaterController) {
    guard !started else { return }
    started = true
    controller.startUpdater()
  }
}

@MainActor
private final class BackgroundCheckGate: NSObject, SPUUpdaterDelegate {
  var holdingBackgroundChecks: Bool

  init(holdingBackgroundChecks: Bool) {
    self.holdingBackgroundChecks = holdingBackgroundChecks
  }

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard holdingBackgroundChecks, updateCheck == .updatesInBackground else { return }
    throw CocoaError(.userCancelled)
  }
}
