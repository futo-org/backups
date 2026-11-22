import AppKit
import BackupsCore
import SwiftUI

struct RecoveryKeyOnboarding: View {
  @Environment(AppModel.self) private var model
  @State private var key: String?

  var body: some View {
    ZStack {
      OnboardingBackground()
      ScrollView {
        VStack(spacing: 0) {
          if !model.isRecoveringLostKey {
            StepIndicator(current: model.recoveryKeyStep == .save ? 1 : 2)
              .padding(.bottom, 30)
          }
          switch model.recoveryKeyStep {
          case .save, nil:
            SaveRecoveryKeyStep(key: key)
          case .confirm:
            ConfirmRecoveryKeyStep()
          case .importKey:
            ImportRecoveryKeyStep()
          case .chooseRepository(let list):
            ChooseRepositoryStep(repositories: list)
          }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
      }
    }
    .task { key = await model.recoveryKey() }
  }
}

struct OnboardingBackground: View {
  var body: some View {
    RadialGradient(colors: [Brand.blue.opacity(0.2), .clear], center: .top, startRadius: 0, endRadius: 520)
      .ignoresSafeArea()
  }
}

private struct StepIndicator: View {
  let current: Int
  private let titles = ["Sign in", "Save key", "Confirm"]

  var body: some View {
    HStack(spacing: 10) {
      ForEach(titles.indices, id: \.self) { index in
        if index > 0 {
          Capsule()
            .fill(index <= current ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.12)))
            .frame(width: 36, height: 2)
        }
        HStack(spacing: 6) {
          ZStack {
            Circle()
              .fill(index <= current ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)))
              .frame(width: 20, height: 20)
            if index < current {
              Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
            } else {
              Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(index == current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            }
          }
          Text(titles[index])
            .font(.system(size: 12, weight: index == current ? .semibold : .regular))
            .foregroundStyle(index == current ? .primary : .secondary)
        }
      }
    }
  }
}

private struct StepTitle: View {
  let systemName: String
  let tint: Color
  let title: String
  let subtitle: String

  var body: some View {
    VStack(spacing: 10) {
      IconTile(systemName: systemName, tint: tint, size: 52)
        .padding(.bottom, 6)
      Text(title)
        .font(.system(size: 28, weight: .bold, design: .rounded))
      Text(subtitle)
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct SaveRecoveryKeyStep: View {
  @Environment(AppModel.self) private var model
  let key: String?
  @State private var saved = false

  var body: some View {
    VStack(spacing: 22) {
      StepTitle(
        systemName: "key.fill", tint: .orange, title: "Save your recovery key",
        subtitle:
          "Your backups are encrypted on this Mac with this key. FUTO can't restore them without it, "
          + "and can't recover the key if you lose it.")
      if let key {
        VStack(spacing: 10) {
          RecoveryKeyCard(key: key)
          Text("This is one key. It is split across lines only to make it easier to read.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        RecoveryKeyActions(key: key)
      } else {
        ProgressView()
          .frame(height: 160)
      }
      Toggle("I saved my recovery key somewhere safe.", isOn: $saved)
        .toggleStyle(.checkbox)
        .padding(.top, 4)
      Button("Continue") { model.showRecoveryKeyStep(.confirm) }
        .buttonStyle(PrimaryButtonStyle(large: true))
        .disabled(!saved || key == nil)
        .keyboardShortcut(.defaultAction)
      if model.canImportRecoveryKey {
        Button("I already have a recovery key") { model.showRecoveryKeyStep(.importKey) }
          .buttonStyle(.link)
          .font(.system(size: 12))
      }
    }
  }
}

private struct ConfirmRecoveryKeyStep: View {
  @Environment(AppModel.self) private var model
  @State private var input = ""
  @State private var mismatch = false
  @State private var checking = false

  var body: some View {
    VStack(spacing: 22) {
      StepTitle(
        systemName: "checkmark.shield.fill", tint: .green, title: "Confirm your recovery key",
        subtitle: "Enter the key exactly as you saved it, to make sure your copy is correct. "
          + "Spaces and capital letters don't matter.")
      KeyField(text: $input, invalid: mismatch) { confirm() }
        .onChange(of: input) { _, _ in mismatch = false }
      if mismatch {
        Label("That key doesn't match. Check your copy and try again.", systemImage: "xmark.octagon.fill")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.red)
      }
      Button("Confirm") { confirm() }
        .buttonStyle(PrimaryButtonStyle(large: true))
        .disabled(input.isEmpty || checking)
        .keyboardShortcut(.defaultAction)
      Button("View recovery key again") { model.showRecoveryKeyStep(.save) }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
  }

  private func confirm() {
    checking = true
    Task {
      mismatch = !(await model.confirmRecoveryKey(input))
      checking = false
    }
  }
}

private struct ImportRecoveryKeyStep: View {
  @Environment(AppModel.self) private var model
  @State private var input = ""
  @State private var errorMessage: String?
  @State private var checking = false

  var body: some View {
    VStack(spacing: 22) {
      StepTitle(
        systemName: "key.horizontal.fill", tint: Brand.blue,
        title: model.isRecoveringLostKey ? "Enter your recovery key" : "Use your existing recovery key",
        subtitle: model.isRecoveringLostKey
          ? "This Mac's recovery key is missing. Enter it to keep backing up."
          : "Enter the recovery key you saved on another device. "
            + "This Mac will encrypt its backups with it.")
      KeyField(text: $input, invalid: errorMessage != nil) { use() }
        .onChange(of: input) { _, _ in errorMessage = nil }
      Text(hint)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(errorMessage != nil ? .red : .secondary)
      if checking {
        ProgressView()
          .controlSize(.small)
      } else {
        Button("Use This Key") { use() }
          .buttonStyle(PrimaryButtonStyle(large: true))
          .disabled(RepositoryKeys.normalizedMasterKey(input) == nil)
          .keyboardShortcut(.defaultAction)
      }
      if !model.isRecoveringLostKey {
        Button("Back") { model.showRecoveryKeyStep(.save) }
          .buttonStyle(.link)
          .font(.system(size: 12))
      }
    }
  }

  private var hint: String {
    if let errorMessage { return errorMessage }
    let length = input.filter { $0.isHexDigit }.count
    return RepositoryKeys.normalizedMasterKey(input) != nil
      ? "Looks good." : "A recovery key has 64 characters (0–9 and A–F). \(length) of 64 so far."
  }

  private func use() {
    guard RepositoryKeys.normalizedMasterKey(input) != nil, !checking else { return }
    checking = true
    Task {
      errorMessage = await model.importRecoveryKey(input)
      checking = false
    }
  }
}

private struct ChooseRepositoryStep: View {
  @Environment(AppModel.self) private var model
  let repositories: [RemoteRepository]
  @State private var verifyingId: String?
  @State private var failedId: String?
  @State private var errorMessage: String?
  @State private var starting = false

  var body: some View {
    VStack(spacing: 22) {
      StepTitle(
        systemName: "externaldrive.fill.badge.checkmark", tint: Brand.blue, title: "Continue an existing backup",
        subtitle: "Choose the backup this Mac should continue. Your recovery key is checked against it.")
      VStack(spacing: 0) {
        ForEach(Array(repositories.enumerated()), id: \.element.id) { index, repository in
          if index > 0 {
            Divider()
          }
          Button {
            choose(repository)
          } label: {
            HStack(spacing: 12) {
              IconTile(systemName: "laptopcomputer", tint: Brand.blue, size: 32)
              VStack(alignment: .leading, spacing: 2) {
                Text(repository.name)
                  .font(.system(size: 13, weight: .semibold))
                Text(detail(for: repository))
                  .font(.system(size: 12))
                  .foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
              if verifyingId == repository.id {
                ProgressView()
                  .controlSize(.small)
              } else {
                Image(systemName: "chevron.right")
                  .foregroundStyle(.secondary)
              }
            }
            .contentShape(Rectangle())
            .padding(12)
          }
          .buttonStyle(.plain)
          .disabled(verifyingId != nil)
          if failedId == repository.id, let errorMessage {
            Text(errorMessage)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(.red)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 12)
              .padding(.bottom, 10)
          }
        }
      }
      .padding(6)
      .frame(maxWidth: .infinity)
      .background(CardBackground())
      VStack(spacing: 10) {
        Button("Start a New Backup Instead") { startNew() }
          .buttonStyle(SecondaryButtonStyle())
          .disabled(verifyingId != nil)
        if failedId == nil, let errorMessage {
          Text(errorMessage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.red)
        }
      }
    }
  }

  private func detail(for repository: RemoteRepository) -> String {
    let size = Format.bytes(repository.sizeBytes)
    guard let lastBackup = repository.lastBackup, let date = parseDate(lastBackup) else {
      return "\(size) · No backups yet"
    }
    return "\(size) · \(Format.relative(date))"
  }

  private func parseDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) {
      return date
    }
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: value)
  }

  private func choose(_ repository: RemoteRepository) {
    guard verifyingId == nil else { return }
    verifyingId = repository.id
    failedId = nil
    errorMessage = nil
    Task {
      let message = await model.chooseRepository(repository)
      verifyingId = nil
      failedId = message == nil ? nil : repository.id
      errorMessage = message
    }
  }

  private func startNew() {
    guard verifyingId == nil, !starting else { return }
    starting = true
    failedId = nil
    errorMessage = nil
    Task {
      errorMessage = await model.startNewBackupWithPendingKey()
      starting = false
    }
  }
}

private struct KeyField: View {
  @Binding var text: String
  let invalid: Bool
  let submit: () -> Void

  var body: some View {
    TextField("Recovery key", text: $text, prompt: Text("0000 0000 0000 0000 …"), axis: .vertical)
      .textFieldStyle(.plain)
      .font(.system(size: 16, weight: .medium, design: .monospaced))
      .lineLimit(2...4)
      .autocorrectionDisabled()
      .onSubmit(submit)
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.primary.opacity(0.05))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(invalid ? Color.red : Brand.blue.opacity(0.4), lineWidth: invalid ? 1.5 : 1)))
  }
}

struct RecoveryKeyCard: View {
  let key: String

  var body: some View {
    VStack(spacing: 6) {
      ForEach(RepositoryKeys.displayLines(key), id: \.self) { line in
        Text(line)
          .font(.system(size: 19, weight: .semibold, design: .monospaced))
          .tracking(1.5)
      }
    }
    .textSelection(.enabled)
    .padding(.vertical, 22)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Brand.blue.opacity(0.1))
        .overlay(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Brand.blue.opacity(0.3), lineWidth: 1)))
  }
}

struct RecoveryKeyActions: View {
  let key: String
  @State private var copied = false
  @State private var savedFile = false

  var body: some View {
    HStack(spacing: 10) {
      Button {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(singleLine, forType: .string)
        copied = true
      } label: {
        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
      }
      Button {
        saveToFile()
      } label: {
        Label(savedFile ? "Saved" : "Save to File…", systemImage: savedFile ? "checkmark" : "square.and.arrow.down")
      }
      Button {
        printKey()
      } label: {
        Label("Print…", systemImage: "printer")
      }
    }
    .buttonStyle(SecondaryButtonStyle())
  }

  private var singleLine: String {
    RepositoryKeys.displayLines(key).joined(separator: " ")
  }

  private var document: String {
    "FUTO Backups recovery key\n\n" + RepositoryKeys.displayLines(key).joined(separator: "\n")
      + "\n\nThis is one key. Keep it somewhere safe: you need it to restore your backups.\n"
  }

  private func saveToFile() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "FUTO Backups Recovery Key.txt"
    panel.allowedContentTypes = [.plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try document.write(to: url, atomically: true, encoding: .utf8)
      savedFile = true
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  private func printKey() {
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 240))
    view.string = document
    view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    NSPrintOperation(view: view).run()
  }
}
