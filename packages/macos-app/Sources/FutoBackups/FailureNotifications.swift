import AppKit
import BackupsCore
import UserNotifications

@MainActor
final class FailureNotifications: NSObject, UNUserNotificationCenterDelegate, FailureNotificationCenter {
  static let shared = FailureNotifications()

  private static let identifier = "backup-failed"

  private var center: UNUserNotificationCenter? {
    Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
  }

  func install() {
    center?.delegate = self
  }

  func requestPermission() async -> Bool {
    guard let center else { return false }
    do {
      _ = try await center.requestAuthorization(options: [.alert])
      return true
    } catch {
      return false
    }
  }

  func post(_ notice: FailureNotice) async -> Bool {
    guard let center else { return false }
    let status = await center.notificationSettings().authorizationStatus
    guard status == .authorized || status == .provisional else { return false }
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    content.interruptionLevel = .active
    do {
      try await center.add(UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil))
      return true
    } catch {
      return false
    }
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
