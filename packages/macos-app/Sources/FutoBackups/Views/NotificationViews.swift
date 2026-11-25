import BackupsCore
import SwiftUI

struct FailureNotificationSetting: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    let toggle = model.failureNotificationToggle
    Toggle(isOn: binding(toggle)) {
      SettingLabel(
        systemName: "bell.badge.fill", tint: .red, title: "Notify me if a scheduled backup fails",
        detail: "One notification when backups stop working, and none until one succeeds again.")
    }
    .disabled(model.isRequestingNotificationPermission)
    if toggle.showsDeniedNote {
      HStack(spacing: 10) {
        Image(systemName: "bell.slash.fill")
          .foregroundStyle(.orange)
        Text("Notifications for FUTO Backups are turned off in System Settings.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Open System Settings") { model.openNotificationSettings() }
          .buttonStyle(.bordered)
      }
    }
  }

  private func binding(_ toggle: FailureNotificationToggle) -> Binding<Bool> {
    Binding(get: { toggle.isOn }, set: { model.setFailureNotifications($0) })
  }
}

struct FailureNotificationHint: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Card(padding: 16) {
      HStack(spacing: 12) {
        IconTile(systemName: "bell.badge.fill", tint: .red, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text("Get notified if a backup fails")
            .font(.system(size: 13, weight: .semibold))
          Text("FUTO Backups can tell you when a scheduled backup doesn't finish.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        Button("Turn On") { model.setFailureNotifications(true) }
          .buttonStyle(.borderedProminent)
          .tint(Brand.fill)
        Button {
          model.dismissFailureNotificationHint()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
      }
    }
  }
}
