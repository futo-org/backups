import BackupsCore
import SwiftUI

struct RetentionSection: View {
  private enum Choice: Hashable {
    case preset(RetentionPreset)
    case custom
  }

  @Environment(AppModel.self) private var model
  @State private var editingCustom = false
  @State private var draft = RetentionDraft()
  @State private var fieldErrors: [RetentionField: RetentionInputError] = [:]
  @State private var draftError: String?
  @State private var pendingRetention: SnapshotRetention?

  var body: some View {
    Section {
      Picker(selection: choiceBinding) {
        ForEach(RetentionPreset.allCases) { preset in
          Text(preset.label).tag(Choice.preset(preset))
        }
        Divider()
        Text("Custom…").tag(Choice.custom)
      } label: {
        SettingLabel(
          systemName: "clock.arrow.circlepath", tint: .teal, title: "Delete old snapshots",
          detail: "\(model.config.snapshotRetention.summary).")
      }
      if editingCustom {
        ForEach(RetentionField.allCases) { field in
          LabeledContent {
            TextField("", text: $draft[field], prompt: Text(field.placeholder))
              .textFieldStyle(.roundedBorder)
              .multilineTextAlignment(.trailing)
              .frame(width: 90)
              .onSubmit(applyCustom)
              .onChange(of: draft[field]) { _, _ in
                fieldErrors[field] = nil
                draftError = nil
              }
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(field.title)
              Text(field.detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
          }
          if let error = fieldErrors[field] {
            InlineError(text: error.message)
          }
        }
        HStack(spacing: 12) {
          Text("Durations count back from the latest backup: h hours, d days, m months, y years, like 1y6m.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
          Spacer()
          Button("Apply", action: applyCustom)
            .disabled(draftMatchesCurrent)
        }
        if let draftError {
          InlineError(text: draftError)
        }
      }
    } header: {
      Text("Snapshots")
    } footer: {
      Text(
        "Applies after the next backup. Deleted snapshots can't be recovered, and keeping more snapshots uses more storage."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .alert("Delete more old snapshots?", isPresented: confirmingBinding, presenting: pendingRetention) { retention in
      Button("Delete Old Snapshots", role: .destructive) { apply(retention) }
      Button("Cancel", role: .cancel) {}
    } message: { retention in
      Text(
        "“\(retention.summary)” can delete snapshots your current setting would keep. It applies to backups started after this change, and deleted snapshots can't be recovered."
      )
    }
    .onAppear(perform: syncDraft)
  }

  private var choiceBinding: Binding<Choice> {
    Binding(
      get: {
        guard !editingCustom, let preset = RetentionPreset(model.config.snapshotRetention) else { return .custom }
        return .preset(preset)
      },
      set: { choice in
        switch choice {
        case .preset(let preset):
          request(preset.retention)
        case .custom:
          editingCustom = true
        }
      })
  }

  private var confirmingBinding: Binding<Bool> {
    Binding(
      get: { pendingRetention != nil },
      set: { if !$0 { pendingRetention = nil } })
  }

  private var draftMatchesCurrent: Bool {
    guard let policy = try? draft.policy() else { return false }
    return .policy(policy) == model.config.snapshotRetention
  }

  private func syncDraft() {
    let retention = model.config.snapshotRetention
    editingCustom = RetentionPreset(retention) == nil
    if case .policy(let policy) = retention {
      draft = RetentionDraft(policy)
    } else {
      draft = RetentionDraft()
    }
    fieldErrors = [:]
    draftError = nil
  }

  private func applyCustom() {
    do {
      request(.policy(try draft.policy()))
    } catch {
      fieldErrors = draft.errors
      draftError = fieldErrors.isEmpty ? error.message : nil
    }
  }

  private func request(_ retention: SnapshotRetention) {
    if retention.mayDeleteMore(than: model.config.snapshotRetention) {
      pendingRetention = retention
    } else {
      apply(retention)
    }
  }

  private func apply(_ retention: SnapshotRetention) {
    pendingRetention = nil
    model.setRetention(retention)
    syncDraft()
  }
}

struct RetentionPresetPicker: View {
  @Binding var selection: RetentionPreset

  var body: some View {
    Picker("Keep snapshots", selection: $selection) {
      ForEach(RetentionPreset.allCases) { preset in
        Text(preset.keepLabel).tag(preset)
      }
    }
    .labelsHidden()
    .fixedSize()
  }
}
