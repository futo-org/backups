import AppKit
import BackupsCore
import SwiftUI

struct BackupConditionsSection: View {
  @Environment(AppModel.self) private var model
  @State private var attachedDevices: [USBDevice] = []

  var body: some View {
    Section {
      Toggle(isOn: keepAwakeBinding) {
        SettingLabel(
          systemName: "cup.and.saucer.fill", tint: .brown, title: "Keep this Mac awake",
          detail:
            "Stops this Mac from going to sleep on its own during a backup. Closing the lid still puts it to sleep.")
      }
      Toggle(isOn: conditionBinding(\.power)) {
        SettingLabel(
          systemName: "bolt.fill", tint: .green, title: "Only when on power",
          detail: "Scheduled backups wait while this Mac runs on battery.")
      }
      Toggle(isOn: conditionBinding(\.ethernet)) {
        SettingLabel(
          systemName: "cable.connector", tint: .blue, title: "Only when on Ethernet",
          detail: "Scheduled backups wait while this Mac uses Wi-Fi.")
      }
      Toggle(isOn: conditionBinding(\.externalDisplay)) {
        SettingLabel(
          systemName: "display", tint: .purple, title: "Only with an external display",
          detail: "Use this to back up only while this Mac is docked.")
      }
      Picker(selection: deviceBinding) {
        Text("Off").tag(USBDevice?.none)
        ForEach(deviceChoices, id: \.self) { device in
          Text(deviceLabel(device)).tag(USBDevice?.some(device))
        }
      } label: {
        SettingLabel(
          systemName: "cable.connector.horizontal", tint: .teal, title: "Only with a USB device",
          detail: "Choose your dock, or another device that is only attached at your desk.")
      }
      if !conditions.required.isEmpty {
        Picker(selection: runAnywayBinding) {
          Text("Never").tag(Int?.none)
          ForEach(BackupConditions.runAnywayChoices, id: \.self) { days in
            Text(days == 1 ? "After 1 day" : "After \(days) days").tag(Int?.some(days))
          }
        } label: {
          SettingLabel(
            systemName: "clock.badge.exclamationmark", tint: .orange, title: "Back up anyway",
            detail: "If the conditions stay unmet for this long, the scheduled backup runs without them.")
        }
        if !model.waitingFor.isEmpty {
          Text("\(BackupCondition.waitingText(model.waitingFor)).")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Scheduled backups")
    } footer: {
      Text("Back Up Now does not wait for these conditions.")
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
    .task {
      while !Task.isCancelled {
        refreshDevices()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private var conditions: BackupConditions { model.config.backupConditions }

  private var deviceChoices: [USBDevice] {
    guard let chosen = conditions.usbDevice else { return attachedDevices }
    let others = attachedDevices.filter { !$0.isSameModel(as: chosen) }
    return ([chosen] + others).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func deviceLabel(_ device: USBDevice) -> String {
    let sharesName = deviceChoices.contains { $0.name == device.name && !$0.isSameModel(as: device) }
    let name = sharesName ? "\(device.name) (\(device.modelCode))" : device.name
    return attachedDevices.contains { $0.isSameModel(as: device) } ? name : "\(name) (not attached)"
  }

  private func refreshDevices() {
    let devices = MachineProbe.usbDevices()
    if attachedDevices != devices { attachedDevices = devices }
  }

  private func conditionBinding(_ keyPath: WritableKeyPath<BackupConditions, Bool>) -> Binding<Bool> {
    Binding(
      get: { conditions[keyPath: keyPath] },
      set: { enabled in
        var changed = conditions
        changed[keyPath: keyPath] = enabled
        model.setBackupConditions(changed)
      })
  }

  private var deviceBinding: Binding<USBDevice?> {
    Binding(
      get: { conditions.usbDevice },
      set: { device in
        var changed = conditions
        changed.usbDevice = device
        model.setBackupConditions(changed)
      })
  }

  private var runAnywayBinding: Binding<Int?> {
    Binding(
      get: { conditions.runAnywayAfterDays },
      set: { days in
        var changed = conditions
        changed.runAnywayAfterDays = days
        model.setBackupConditions(changed)
      })
  }

  private var keepAwakeBinding: Binding<Bool> {
    Binding(get: { model.config.keepsAwake }, set: { model.setKeepAwake($0) })
  }
}
