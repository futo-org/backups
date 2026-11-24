import AppKit
import BackupsCore
import UserNotifications

@MainActor
final class FailureNotifications: NSObject, UNUserNotificationCenterDelegate {
  static let shared = FailureNotifications()

  private static let identifier = "backup-failed"

  private var center: UNUserNotificationCenter? {
    Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
  }

  func install() {
    center?.delegate = self
  }

  func requestPermission() async {
    _ = try? await center?.requestAuthorization(options: [.alert])
  }

  func post(_ notice: FailureNotice) async {
    guard let center else { return }
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    content.interruptionLevel = .active
    try? await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
  }

  func withdraw() {
    center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    await MainActor.run { MenuBarResidency.shared.showMainWindow() }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    await MainActor.run { NSApp.isActive } ? [.list] : [.banner, .list]
  }
}
