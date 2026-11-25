import AppKit
import BackupsCore
import UserNotifications

@MainActor
final class FailureNotifications: NSObject, UNUserNotificationCenterDelegate, FailureNotificationCenter {
  static let shared = FailureNotifications()

  private var center: UNUserNotificationCenter? {
    Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
  }

  static var systemSettingsURL: URL? {
    let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    guard let bundleId = Bundle.main.bundleIdentifier else { return URL(string: pane) }
    return URL(string: "\(pane)?id=\(bundleId)")
  }

  func install() {
    center?.delegate = self
  }

  func authorization() async -> NotificationAuthorization {
    guard let center else { return .notDetermined }
    return NotificationAuthorization(await center.notificationSettings().authorizationStatus)
  }

  func requestAuthorization() async -> NotificationAuthorization? {
    guard let center else { return nil }
    do {
      return try await center.requestAuthorization(options: [.alert]) ? .authorized : .denied
    } catch {
      return nil
    }
  }

  func post(_ notice: FailureNotice, id: String, isCurrent: @escaping @MainActor () -> Bool) async -> Bool {
    guard let center else { return false }
    let status = await center.notificationSettings().authorizationStatus
    guard NotificationAuthorization(status) == .authorized, isCurrent() else { return false }
    let content = UNMutableNotificationContent()
    content.title = notice.title
    content.body = notice.body
    content.interruptionLevel = .active
    do {
      try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
      return true
    } catch {
      return false
    }
  }

  func withdraw(id: String) {
    center?.removeDeliveredNotifications(withIdentifiers: [id])
  }

  func withdrawAll() {
    center?.removeAllDeliveredNotifications()
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

extension NotificationAuthorization {
  fileprivate init(_ status: UNAuthorizationStatus) {
    switch status {
    case .authorized, .provisional, .ephemeral: self = .authorized
    case .denied: self = .denied
    case .notDetermined: self = .notDetermined
    @unknown default: self = .notDetermined
    }
  }
}
