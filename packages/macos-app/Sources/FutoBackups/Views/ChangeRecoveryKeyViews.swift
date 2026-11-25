import BackupsCore
import SwiftUI

struct ChangeRecoveryKeySheet: View {
  enum Step: Equatable {
    case explain
    case save
    case confirm
    case applying
    case done(KeyRotationOutcome)
    case failed(String)
  }

  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var step = Step.explain
  @State private var newKey = RepositoryKeys.generateMasterKey()
  @State private var saved = false
  @State private var input = ""
  @State private var mismatch = false
  @State private var authenticating = false
  @State private var pendingChange: Task<Void, Never>?

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        switch step {
        case .explain:
          explainStep
        case .save:
          saveStep
        case .confirm:
          confirmStep
        case .applying:
          applyingStep
        case .done(let outcome):
          doneStep(outcome)
        case .failed(let message):
          failedStep(message)
        }
      }
      .padding(36)
    }
    .frame(width: 560)
    .frame(minHeight: 420)
    .background(OnboardingBackground())
    .interactiveDismissDisabled(step == .applying)
    .onDisappear { pendingChange?.cancel() }
  }

  private var explainStep: some View {
    Group {
      StepTitle(
        systemName: "key.fill", tint: .orange, title: "Change recovery key",
        subtitle: "Replace the recovery key that encrypts this Mac's backup with a new one.")
      VStack(alignment: .leading, spacing: 14) {
        ChangeKeyPoint(
          systemName: "laptopcomputer", tint: Brand.blue,
          text: "Only this Mac's backup changes. Other Macs and the FUTO Backups standalone app keep the key "
            + "they use now.")
        ChangeKeyPoint(
          systemName: "key.horizontal.fill", tint: .orange,
          text: "Your current key stops opening this Mac's backup once the change is done.")
        ChangeKeyPoint(
          systemName: "exclamationmark.triangle.fill", tint: .red,
          text: "Your backup isn't re-encrypted. Anyone who already opened it with the old key may still be able "
            + "to read it.")
      }
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(CardBackground())
      buttons(primary: "Continue") { step = .save }
    }
  }

  private var saveStep: some View {
    Group {
      StepTitle(
        systemName: "key.fill", tint: .orange, title: "Save your new recovery key",
        subtitle: "You need it to restore this Mac's backup. FUTO can't recover it if you lose it.")
      VStack(spacing: 10) {
        RecoveryKeyCard(key: newKey)
        Text("This is one key. It is split across lines only to make it easier to read.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      RecoveryKeyActions(key: newKey)
      Toggle("I saved my new recovery key somewhere safe.", isOn: $saved)
        .toggleStyle(.checkbox)
      buttons(primary: "Continue", disabled: !saved) { step = .confirm }
    }
  }

  private var confirmStep: some View {
    Group {
      StepTitle(
        systemName: "checkmark.shield.fill", tint: .green, title: "Confirm your new recovery key",
        subtitle: "Enter the new key exactly as you saved it. Spaces and capital letters don't matter.")
      KeyField(text: $input, invalid: mismatch) { confirm() }
        .onChange(of: input) { _, _ in mismatch = false }
      if mismatch {
        Label("That key doesn't match. Check your copy and try again.", systemImage: "xmark.octagon.fill")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.red)
      }
      buttons(primary: "Change Key", disabled: input.isEmpty || authenticating) { confirm() }
      Button("View New Key Again") { step = .save }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
  }

  private var applyingStep: some View {
    VStack(spacing: 16) {
      ProgressView()
        .controlSize(.large)
      Text("Changing your recovery key")
        .font(.system(size: 20, weight: .bold, design: .rounded))
      Text("Keep FUTO Backups open until this finishes.")
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 300)
  }

  private func doneStep(_ outcome: KeyRotationOutcome) -> some View {
    Group {
      StepTitle(
        systemName: "checkmark.seal.fill", tint: .green, title: "Recovery key changed",
        subtitle: outcome == .complete
          ? "This Mac's backup now uses your new key. The old key no longer opens it."
          : "This Mac's backup now uses your new key. The old key will stop working after the next backup.")
      Button("Done") { dismiss() }
        .buttonStyle(PrimaryButtonStyle(large: true))
        .keyboardShortcut(.defaultAction)
        .onEscape { dismiss() }
    }
  }

  private func failedStep(_ message: String) -> some View {
    Group {
      StepTitle(
        systemName: "xmark.octagon.fill", tint: .red, title: "Couldn't change the recovery key",
        subtitle: message + " Your current recovery key still works.")
      buttons(primary: "Try Again", cancelTitle: "Close", disabled: authenticating) { apply() }
    }
  }

  private func buttons(
    primary: String, cancelTitle: String = "Cancel", disabled: Bool = false, action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 12) {
      Button(cancelTitle) { dismiss() }
        .buttonStyle(SecondaryButtonStyle())
        .keyboardShortcut(.cancelAction)
      Button(primary, action: action)
        .buttonStyle(PrimaryButtonStyle(large: true))
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
    }
    .padding(.top, 4)
  }

  private func confirm() {
    guard RepositoryKeys.matches(input, masterKey: newKey) else {
      mismatch = true
      return
    }
    apply()
  }

  private func apply() {
    authenticating = true
    pendingChange = Task {
      let authentication = await OwnerAuthentication.confirm(reason: "change your recovery key")
      authenticating = false
      guard !Task.isCancelled else { return }
      switch authentication {
      case .confirmed: break
      case .declined: return
      case .unavailable:
        step = .failed(OwnerAuthentication.unavailableMessage)
        return
      }
      step = .applying
      switch await model.changeRecoveryKey(to: newKey) {
      case .success(let outcome):
        step = .done(outcome)
      case .failure(let failure):
        step = .failed(failure.message)
      }
    }
  }
}

private struct ChangeKeyPoint: View {
  let systemName: String
  let tint: Color
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      IconTile(systemName: systemName, tint: tint, size: 26)
      Text(text)
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
