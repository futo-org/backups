import AppKit
import BackupsCore
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var limitDraft = ""
  @State private var quietEnabled = false
  @State private var quietStart = SettingsView.clockDate(hour: 22, minute: 0)
  @State private var quietEnd = SettingsView.clockDate(hour: 7, minute: 0)
  @State private var recoveryKey: String?

  var body: some View {
    Form {
      Section("Upload limit") {
        TextField("KB/s", text: $limitDraft)
          .textFieldStyle(.roundedBorder)
          .frame(width: 120)
        HStack {
          Button("Apply") { applyLimit() }
          Text("0 means unlimited")
            .foregroundStyle(.secondary)
        }
      }
      Section("Quiet hours") {
        Toggle("Throttle during quiet hours", isOn: $quietEnabled)
          .onChange(of: quietEnabled) { _, _ in applyQuiet() }
        DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
          .onChange(of: quietStart) { _, _ in applyQuiet() }
        DatePicker("To", selection: $quietEnd, displayedComponents: .hourAndMinute)
          .onChange(of: quietEnd) { _, _ in applyQuiet() }
      }
      Section("Startup") {
        Toggle("Launch at login", isOn: launchAtLoginBinding)
      }
      Section("Recovery key") {
        if let recoveryKey {
          Text(recoveryKey)
            .textSelection(.enabled)
            .font(.system(.body, design: .monospaced))
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recoveryKey, forType: .string)
          }
        } else {
          Button("Reveal recovery key") {
            Task {
              self.recoveryKey = await self.model.recoveryKey()
            }
          }
          Text("Store it somewhere safe. You need it to restore your backups after reinstalling.")
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: syncDrafts)
  }

  private var launchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { model.launchAtLogin },
      set: { model.launchAtLogin = $0 })
  }

  private func syncDrafts() {
    limitDraft = String(model.config.throttle.bytesPerSec / 1024)
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
