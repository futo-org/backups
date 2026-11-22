import AppKit
import BackupsCore
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(Updater.self) private var updater
  @State private var limitDraft = ""
  @State private var quietEnabled = false
  @State private var quietStart = SettingsView.clockDate(hour: 22, minute: 0)
  @State private var quietEnd = SettingsView.clockDate(hour: 7, minute: 0)
  @State private var recoveryKey: String?

  var body: some View {
    Form {
      Section {
        HStack(spacing: 12) {
          Circle()
            .fill(Brand.gradient)
            .frame(width: 40, height: 40)
            .overlay(
              Text(String(model.account?.email.first ?? "F").uppercased())
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white))
          VStack(alignment: .leading, spacing: 2) {
            Text(model.account?.email ?? "Signed in")
              .font(.system(size: 13, weight: .semibold))
            Text("\(model.config.host) · \(model.config.serverURL.host() ?? "")")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Sign Out", role: .destructive) { model.logout() }
            .buttonStyle(SecondaryButtonStyle(tint: .red))
        }
        .padding(.vertical, 4)
      }
      Section("Bandwidth") {
        LabeledContent {
          HStack(spacing: 6) {
            TextField("", text: $limitDraft, prompt: Text("Unlimited"))
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(applyLimit)
            Text("KB/s")
              .foregroundStyle(.secondary)
            Button("Apply", action: applyLimit)
              .disabled(limitDraft == currentLimitText)
          }
        } label: {
          SettingLabel(
            systemName: "speedometer", tint: .green, title: "Upload limit", detail: "Leave empty for no limit.")
        }
        Toggle(isOn: $quietEnabled) {
          SettingLabel(
            systemName: "moon.stars.fill", tint: .indigo, title: "Full speed at night",
            detail: "Ignore the upload limit during these hours.")
        }
        .onChange(of: quietEnabled) { _, _ in applyQuiet() }
        if quietEnabled {
          HStack {
            Spacer()
            DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
              .onChange(of: quietStart) { _, _ in applyQuiet() }
              .fixedSize()
            DatePicker("to", selection: $quietEnd, displayedComponents: .hourAndMinute)
              .onChange(of: quietEnd) { _, _ in applyQuiet() }
              .fixedSize()
          }
        }
      }
      Section("General") {
        Toggle(isOn: launchAtLoginBinding) {
          SettingLabel(
            systemName: "power", tint: .gray, title: "Open at login",
            detail: "Keeps scheduled backups running from the menu bar.")
        }
      }
      Section("Security") {
        VStack(alignment: .leading, spacing: 12) {
          SettingLabel(
            systemName: "key.fill", tint: .orange, title: "Recovery key",
            detail: "Your backups are encrypted with this key. Without it, a reinstalled Mac cannot read them.")
          if let recoveryKey {
            RecoveryKeyCard(key: recoveryKey)
            RecoveryKeyActions(key: recoveryKey)
          } else {
            Button("Reveal Recovery Key") {
              Task {
                self.recoveryKey = await self.model.recoveryKey()
              }
            }
            .buttonStyle(SecondaryButtonStyle())
          }
        }
        .padding(.vertical, 4)
      }
      Section("Diagnostics") {
        SettingLabel(
          systemName: "stethoscope", tint: Brand.blue, title: "Usage and diagnostic data",
          detail: "Shared with FUTO to find problems. Required during the closed beta."
        )
        .padding(.vertical, 4)
      }
      Section("Updates") {
        if updater.isAvailable {
          Toggle(isOn: automaticUpdatesBinding) {
            SettingLabel(
              systemName: "arrow.triangle.2.circlepath", tint: .teal, title: "Check for updates automatically",
              detail: versionText)
          }
          Button("Check Now") { updater.checkForUpdates() }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(!updater.canCheckForUpdates)
        } else {
          SettingLabel(
            systemName: "arrow.triangle.2.circlepath", tint: .gray, title: "Updates",
            detail: "Updates are off in development builds.")
        }
      }
      Section("Advanced") {
        ServerEditor()
          .padding(.vertical, 4)
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .frame(maxWidth: 720)
    .frame(maxWidth: .infinity)
    .onAppear(perform: syncDrafts)
  }

  private var currentLimitText: String {
    model.config.throttle.bytesPerSec > 0 ? String(model.config.throttle.bytesPerSec / 1024) : ""
  }

  private var launchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { model.launchAtLogin },
      set: { model.launchAtLogin = $0 })
  }

  private var automaticUpdatesBinding: Binding<Bool> {
    Binding(
      get: { updater.automaticallyChecksForUpdates },
      set: { updater.automaticallyChecksForUpdates = $0 })
  }

  private var versionText: String {
    let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    return "Version \(shortVersion) (\(buildVersion))"
  }

  private func syncDrafts() {
    limitDraft = currentLimitText
    let parts = model.config.throttle.quietHours.split(separator: "-", maxSplits: 1)
    if parts.count == 2,
      let start = SettingsView.parseClock(parts[0]),
      let end = SettingsView.parseClock(parts[1])
    {
      quietEnabled = true
      quietStart = SettingsView.clockDate(hour: start.hour, minute: start.minute)
      quietEnd = SettingsView.clockDate(hour: end.hour, minute: end.minute)
    } else {
      quietEnabled = false
    }
  }

  private func applyLimit() {
    let kb = Int(limitDraft) ?? 0
    model.setThrottle(
      Throttle(bytesPerSec: max(0, kb) * 1024, quietHours: model.config.throttle.quietHours))
  }

  private func applyQuiet() {
    var quietHours = ""
    if quietEnabled {
      let start = Calendar.current.dateComponents([.hour, .minute], from: quietStart)
      let end = Calendar.current.dateComponents([.hour, .minute], from: quietEnd)
      quietHours =
        String(format: "%02d:%02d", start.hour ?? 0, start.minute ?? 0)
        + "-"
        + String(format: "%02d:%02d", end.hour ?? 0, end.minute ?? 0)
    }
    model.setThrottle(
      Throttle(bytesPerSec: model.config.throttle.bytesPerSec, quietHours: quietHours))
  }

  private static func clockDate(hour: Int, minute: Int) -> Date {
    Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
  }

  private static func parseClock(_ text: Substring) -> (hour: Int, minute: Int)? {
    let parts = text.split(separator: ":")
    guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
    return (hour, minute)
  }
}

struct SettingLabel: View {
  let systemName: String
  let tint: Color
  let title: String
  let detail: String

  var body: some View {
    HStack(spacing: 12) {
      IconTile(systemName: systemName, tint: tint, size: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
    }
  }
}
