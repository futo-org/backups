import AppKit
import BackupsCore
import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(Updater.self) private var updater
  @State private var limitDraft = ""
  @State private var revealing = false
  @State private var formMargin: CGFloat = 0
  @State private var limitError: String?
  @FocusState private var limitFocused: Bool
  @State private var quietError: String?
  @State private var quietEnabled = false
  @State private var quietStart = SettingsView.clockDate(ClockTime(hour: 22, minute: 0))
  @State private var quietEnd = SettingsView.clockDate(ClockTime(hour: 7, minute: 0))
  @State private var recoveryKey: String?
  @State private var changingRecoveryKey = false

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
            Text("\(model.config.host) · \(model.config.serverDisplayName)")
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Sign Out", role: .destructive) { model.logout() }
            .buttonStyle(.bordered)
            .tint(.red)
        }
        .padding(.vertical, 4)
      }
      BackupConditionsSection()
      Section("Bandwidth") {
        TextField(text: $limitDraft, prompt: Text("Unlimited")) {
          SettingLabel(
            systemName: "speedometer", tint: .green, title: "Upload limit",
            detail: "In KB/s. Leave empty for no limit.")
        }
        .focused($limitFocused)
        .onSubmit(applyLimit)
        .onChange(of: limitFocused) { _, focused in
          if !focused { applyChangedLimit() }
        }
        .onChange(of: limitDraft) { _, _ in limitError = nil }
        if let limitError {
          InlineError(text: limitError)
        }
        Toggle(isOn: $quietEnabled) {
          SettingLabel(
            systemName: "moon.stars.fill", tint: .indigo, title: "Full speed at night",
            detail: "Ignore the upload limit during these hours.")
        }
        .onChange(of: quietEnabled) { _, _ in applyQuiet() }
        if quietEnabled {
          LabeledContent("Hours") {
            HStack(spacing: 6) {
              DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .onChange(of: quietStart) { _, _ in applyQuiet() }
              Text("to")
                .foregroundStyle(.secondary)
              DatePicker("To", selection: $quietEnd, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .onChange(of: quietEnd) { _, _ in applyQuiet() }
            }
            .fixedSize()
          }
          if let quietError {
            InlineError(text: quietError)
          }
        }
      }
      RetentionSection()
      Section("General") {
        Toggle(isOn: launchAtLoginBinding) {
          SettingLabel(
            systemName: "power", tint: .gray, title: "Open at login",
            detail: "Keeps scheduled backups running from the menu bar.")
        }
        FailureNotificationSetting()
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
            Button("Show Recovery Key") {
              revealing = true
              Task {
                self.recoveryKey = await self.model.revealRecoveryKey()
                revealing = false
              }
            }
            .buttonStyle(.bordered)
            .disabled(revealing)
          }
          Button("Change Recovery Key") { changingRecoveryKey = true }
            .buttonStyle(.bordered)
            .disabled(!model.canChangeRecoveryKey)
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $changingRecoveryKey, onDismiss: reloadRevealedRecoveryKey) {
          ChangeRecoveryKeySheet()
        }
      }
      Section("Disk snapshots") {
        Toggle(isOn: diskSnapshotsBinding) {
          SettingLabel(
            systemName: "clock.arrow.circlepath", tint: Brand.blue, title: "Back up from a disk snapshot",
            detail:
              "FUTO Backups reads folders on this Mac's internal disk from a frozen copy, so files that change during a backup stay consistent. It reads folders on external drives as they are. This needs Full Disk Access."
          )
        }
        if model.config.usesDiskSnapshots && model.hasSnapshotFolders && !model.hasFullDiskAccess {
          HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text(
              "FUTO Backups does not appear to have Full Disk Access. Without it, backups from a disk snapshot fail."
            )
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            Spacer()
            Button("Open Settings") {
              if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
              }
            }
            .buttonStyle(.bordered)
          }
        }
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
            .buttonStyle(.bordered)
            .disabled(!updater.canCheckForUpdates)
        } else {
          SettingLabel(
            systemName: "arrow.triangle.2.circlepath", tint: .gray, title: "Updates",
            detail: "Updates are off in development builds.")
        }
      }
      Section("Advanced") {
        DisclosureGroup("Performance") {
          Picker(selection: uploadConnectionsBinding) {
            Text("Automatic").tag(Int?.none)
            ForEach(AppConfig.parallelismChoices, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
          } label: {
            SettingLabel(
              systemName: "arrow.up.arrow.down", tint: .blue, title: "Simultaneous uploads",
              detail: "Connections to FUTO Cloud at once. Automatic follows the server's recommendation.")
          }
          .padding(.top, 6)
          Picker(selection: readConcurrencyBinding) {
            Text("Automatic").tag(Int?.none)
            ForEach(AppConfig.parallelismChoices, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
          } label: {
            SettingLabel(
              systemName: "doc.on.doc", tint: .teal, title: "Files read at once",
              detail: "More is faster on fast disks. Fewer keeps your Mac more responsive.")
          }
          Text("Changes apply from the next backup.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
        }
        if AppModel.allowsServerSelection {
          ServerEditor()
            .padding(.vertical, 4)
        }
      }
      ThisMacSection()
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .contentMargins(.horizontal, formMargin, for: .scrollContent)
    .onGeometryChange(for: CGFloat.self) {
      max(0, ($0.size.width - 720) / 2)
    } action: {
      formMargin = $0
    }
    .onAppear(perform: syncDrafts)
    .onDisappear {
      if model.signedIn { applyChangedLimit() }
    }
  }

  private var currentLimitText: String {
    UploadLimit.text(bytesPerSecond: model.config.throttle.bytesPerSec)
  }

  private var uploadConnectionsBinding: Binding<Int?> {
    Binding(get: { model.config.uploadConnections }, set: { model.setUploadConnections($0) })
  }

  private var readConcurrencyBinding: Binding<Int?> {
    Binding(get: { model.config.readConcurrency }, set: { model.setReadConcurrency($0) })
  }

  private var launchAtLoginBinding: Binding<Bool> {
    Binding(
      get: { model.launchAtLogin },
      set: { model.launchAtLogin = $0 })
  }

  private var diskSnapshotsBinding: Binding<Bool> {
    Binding(
      get: { model.config.usesDiskSnapshots },
      set: { model.setDiskSnapshots($0) })
  }

  private var automaticUpdatesBinding: Binding<Bool> {
    Binding(
      get: { updater.automaticallyChecksForUpdates },
      set: { updater.automaticallyChecksForUpdates = $0 })
  }

  private var versionText: String {
    let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    return "Version \(shortVersion) (\(buildVersion)), alpha"
  }

  private func reloadRevealedRecoveryKey() {
    guard recoveryKey != nil else { return }
    Task {
      recoveryKey = await model.recoveryKey()
    }
  }

  private func syncDrafts() {
    limitDraft = currentLimitText
    limitError = nil
    quietError = nil
    if let quietHours = QuietHours(parsing: model.config.throttle.quietHours) {
      quietEnabled = true
      quietStart = SettingsView.clockDate(quietHours.start)
      quietEnd = SettingsView.clockDate(quietHours.end)
    } else {
      quietEnabled = false
    }
  }

  private func applyChangedLimit() {
    guard limitDraft != currentLimitText else { return }
    applyLimit()
  }

  private func applyLimit() {
    do {
      let bytesPerSec = try UploadLimit.bytesPerSecond(parsing: limitDraft)
      limitError = nil
      model.setThrottle(Throttle(bytesPerSec: bytesPerSec, quietHours: model.config.throttle.quietHours))
      limitDraft = currentLimitText
    } catch {
      limitError = error.message
    }
  }

  private func applyQuiet() {
    var quietHours = ""
    if quietEnabled {
      do {
        quietHours = try QuietHours(start: SettingsView.clockTime(quietStart), end: SettingsView.clockTime(quietEnd))
          .text
      } catch {
        quietError = error.message
        return
      }
    }
    quietError = nil
    model.setThrottle(
      Throttle(bytesPerSec: model.config.throttle.bytesPerSec, quietHours: quietHours))
  }

  private static func clockDate(_ time: ClockTime) -> Date {
    Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
  }

  private static func clockTime(_ date: Date) -> ClockTime {
    let components = Calendar.current.dateComponents([.hour, .minute], from: date)
    return ClockTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
  }
}

struct InlineError: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.red)
      .copyable(text)
      .frame(maxWidth: .infinity, alignment: .trailing)
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

struct CenteredLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: 0) {
      configuration.label
      Spacer(minLength: 12)
      configuration.content
    }
  }
}

extension LabeledContentStyle where Self == CenteredLabeledContentStyle {
  static var centered: CenteredLabeledContentStyle { CenteredLabeledContentStyle() }
}
