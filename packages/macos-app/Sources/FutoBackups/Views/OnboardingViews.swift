import AppKit
import BackupsCore
import SwiftUI

struct FirstRunOnboarding: View {
  @Environment(AppModel.self) private var model
  @State private var steps: [OnboardingStep] = []
  @State private var index = 0
  @State private var selection = FolderSelection(home: NSHomeDirectory())
  @State private var estimates: FolderSizeEstimates?
  @State private var choices = OnboardingChoices()
  @State private var retention = RetentionPreset.standard

  var body: some View {
    ZStack {
      OnboardingBackground()
      ScrollView {
        VStack(spacing: 0) {
          if !steps.isEmpty {
            StepIndicator(current: index, titles: steps.map(\.title))
              .padding(.bottom, 30)
          }
          if let estimates, steps.indices.contains(index) {
            step(steps[index], estimates: estimates)
          }
        }
        .frame(maxWidth: 580)
        .padding(.horizontal, 40)
        .padding(.vertical, 48)
        .frame(maxWidth: .infinity)
      }
    }
    .onAppear {
      guard steps.isEmpty else { return }
      steps = OnboardingStep.steps(hasFullDiskAccess: model.hasFullDiskAccess)
      estimates = FolderSizeEstimates(sizer: FolderSizer(excludes: model.config.excludes))
    }
    .onDisappear { estimates?.cancelAll() }
  }

  @ViewBuilder
  private func step(_ step: OnboardingStep, estimates: FolderSizeEstimates) -> some View {
    switch step {
    case .fullDiskAccess:
      FullDiskAccessStep(next: { next() })
    case .folders:
      ChooseFoldersStep(
        selection: $selection, estimates: estimates, back: index > 0 ? { back() } : nil, next: { next() })
    case .ready:
      ReadyStep(
        selection: selection, estimates: estimates, choices: $choices, retention: $retention, back: { back() })
    }
  }

  private func next() {
    index = min(index + 1, steps.count - 1)
  }

  private func back() {
    index = max(index - 1, 0)
  }
}

private struct FullDiskAccessStep: View {
  @Environment(AppModel.self) private var model
  let next: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      StepTitle(
        systemName: "lock.shield.fill", tint: Brand.blue, title: "Allow Full Disk Access",
        subtitle: "FUTO Backups needs this permission to back up your Mac reliably.")
      Card {
        VStack(alignment: .leading, spacing: 16) {
          Reason(
            systemName: "camera.aperture", tint: Brand.blue,
            text: "Each backup reads from a frozen snapshot of your disk, so files that change while it runs "
              + "are still saved consistently. Reading that snapshot needs Full Disk Access.")
          Reason(
            systemName: "hand.raised.fill", tint: .orange,
            text: "Without it, macOS asks separately before FUTO Backups can read Documents, Desktop and "
              + "Downloads, and some folders can't be backed up at all.")
          Reason(
            systemName: "eye.slash", tint: .green,
            text: "Your files are encrypted on this Mac before they're uploaded. FUTO can't read them.")
        }
        .padding(.vertical, 4)
      }
      if model.hasFullDiskAccess {
        Label("Full Disk Access is on", systemImage: "checkmark.circle.fill")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.green)
        Button("Continue", action: next)
          .buttonStyle(PrimaryButtonStyle(large: true))
          .keyboardShortcut(.defaultAction)
      } else {
        Text("In System Settings, turn on FUTO Backups in the list, then come back here.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        Button("Open System Settings") { openSettings() }
          .buttonStyle(PrimaryButtonStyle(large: true))
          .keyboardShortcut(.defaultAction)
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Waiting for Full Disk Access…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        Button("Skip for now", action: next)
          .buttonStyle(.link)
          .font(.system(size: 12))
      }
    }
    .task {
      while !Task.isCancelled {
        model.refreshFullDiskAccess()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private func openSettings() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
      NSWorkspace.shared.open(url)
    }
  }
}

private struct Reason: View {
  let systemName: String
  let tint: Color
  let text: String

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      IconTile(systemName: systemName, tint: tint)
      Text(text)
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ChooseFoldersStep: View {
  @Environment(AppModel.self) private var model
  @Binding var selection: FolderSelection
  let estimates: FolderSizeEstimates
  let back: (() -> Void)?
  let next: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      StepTitle(systemName: "folder.fill", tint: Brand.blue, title: "Choose what to back up")
      HStack(spacing: 10) {
        ForEach(FolderBundle.allCases) { bundle in
          BundleCard(bundle: bundle, selected: selection.bundle == bundle) {
            selection.apply(bundle)
          }
        }
      }
      VStack(spacing: 0) {
        ForEach(Array(selection.choices.enumerated()), id: \.element) { position, choice in
          if position > 0 {
            Divider()
              .padding(.leading, 44)
          }
          ChoiceRow(
            choice: choice, selection: $selection,
            size: size(of: choice))
        }
      }
      .padding(6)
      .frame(maxWidth: .infinity)
      .background(CardBackground())
      HStack {
        Button {
          chooseOtherFolders()
        } label: {
          Label("Choose Other Folders…", systemImage: "plus")
        }
        .buttonStyle(SecondaryButtonStyle())
        Spacer()
        Text("Caches and the Trash are always skipped.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      }
      CloudOnlyPolicy(compact: true)
        .padding(12)
        .background(CardBackground())
      Button("Continue", action: next)
        .buttonStyle(PrimaryButtonStyle(large: true))
        .disabled(!selection.canContinue)
        .keyboardShortcut(.defaultAction)
      if let back {
        Button("Back", action: back)
          .buttonStyle(.link)
          .font(.system(size: 12))
      }
    }
    .onChange(of: pathsToMeasure, initial: true) { _, paths in
      estimates.request(paths)
    }
  }

  private var pathsToMeasure: [String] {
    selection.pathsToMeasure(hasFullDiskAccess: model.hasFullDiskAccess)
  }

  private func size(of choice: FolderChoice) -> FolderSize? {
    let path = selection.path(of: choice)
    return pathsToMeasure.contains(path) ? estimates.sizes[path] ?? .calculating : nil
  }

  private func chooseOtherFolders() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Back Up"
    if panel.runModal() == .OK {
      selection.addOthers(panel.urls.map(\.path))
    }
  }
}

private struct BundleCard: View {
  let bundle: FolderBundle
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          IconTile(systemName: bundle.systemName, tint: selected ? Brand.blue : .gray, size: 30)
          Spacer()
          Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 16))
            .foregroundStyle(selected ? AnyShapeStyle(Brand.blue) : AnyShapeStyle(.tertiary))
        }
        Text(bundle.title)
          .font(.system(size: 13, weight: .semibold))
        Text(bundle.detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
      .background(CardBackground())
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(Brand.blue.opacity(selected ? 0.8 : 0), lineWidth: 1.5)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

extension FolderBundle {
  var systemName: String {
    switch self {
    case .essentials: "doc.text.fill"
    case .essentialsAndMedia: "photo.on.rectangle.angled"
    case .everything: "house.fill"
    }
  }

  var title: String {
    switch self {
    case .essentials: "Essentials"
    case .essentialsAndMedia: "Essentials + Media"
    case .everything: "Everything"
    }
  }

  var detail: String {
    switch self {
    case .essentials: "Documents and Desktop."
    case .essentialsAndMedia: "Adds Pictures, including your Photos library, Movies and Music."
    case .everything: "Your whole home folder. Caches and the Trash are skipped."
    }
  }
}

private struct ChoiceRow: View {
  let choice: FolderChoice
  @Binding var selection: FolderSelection
  let size: FolderSize?

  var body: some View {
    HStack(spacing: 12) {
      Toggle("", isOn: isOn)
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(covered)
      Image(nsImage: NSWorkspace.shared.icon(forFile: path))
        .resizable()
        .frame(width: 28, height: 28)
      VStack(alignment: .leading, spacing: 2) {
        Text(name)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Text(covered ? "Included in your home folder" : Format.abbreviatedPath(path))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
      Spacer(minLength: 8)
      SizeLabel(size: size)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 7)
    .opacity(covered ? 0.6 : 1)
    .contentShape(Rectangle())
    .onTapGesture {
      guard !covered else { return }
      isOn.wrappedValue.toggle()
    }
  }

  private var path: String { selection.path(of: choice) }

  private var covered: Bool { selection.coveringChoice(of: choice) != nil }

  private var isOn: Binding<Bool> {
    Binding(
      get: { selection.isIncluded(choice) },
      set: { selection.set(choice, selected: $0) })
  }

  private var name: String {
    switch choice {
    case .home: "Entire home folder"
    case .standard(let folder): folder.rawValue
    case .other(let path): URL(fileURLWithPath: path).lastPathComponent
    }
  }
}

private struct SizeLabel: View {
  let size: FolderSize?

  var body: some View {
    switch size {
    case .calculating:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.mini)
        Text("Calculating…")
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    case .bytes(let bytes):
      Text(Format.bytes(bytes))
        .font(.system(size: 12, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    case .unavailable:
      Text("—")
        .foregroundStyle(.tertiary)
        .help("This folder couldn't be read.")
    case nil:
      EmptyView()
    }
  }
}

private struct ReadyStep: View {
  @Environment(AppModel.self) private var model
  @Environment(Updater.self) private var updater
  let selection: FolderSelection
  let estimates: FolderSizeEstimates
  @Binding var choices: OnboardingChoices
  @Binding var retention: RetentionPreset
  let back: () -> Void
  @State private var pendingBackUpNow: Bool?

  var body: some View {
    VStack(spacing: 22) {
      StepTitle(
        systemName: "checkmark.seal.fill", tint: .green, title: "Ready to back up",
        subtitle: "Your files are encrypted on this Mac before they're uploaded.")
      Card {
        VStack(alignment: .leading, spacing: 14) {
          SummaryRow(systemName: "folder.fill", tint: Brand.blue, title: "Folders", value: foldersSummary) {
            Text(selection.paths.map(Format.abbreviatedPath).joined(separator: ", "))
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .truncationMode(.middle)
          }
          Divider()
          SummaryRow(systemName: "internaldrive.fill", tint: .purple, title: "Estimated size", value: sizeSummary) {
            EmptyView()
          }
          Divider()
          SummaryRow(systemName: "calendar", tint: .orange, title: "Schedule", value: scheduleSummary) {
            Text("You can change this on the Overview page.")
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
          }
          Divider()
          HStack(alignment: .top, spacing: 12) {
            IconTile(systemName: "clock.arrow.circlepath", tint: .teal)
            VStack(alignment: .leading, spacing: 3) {
              HStack {
                Text("Keep snapshots")
                  .font(.system(size: 13, weight: .semibold))
                Spacer()
                RetentionPresetPicker(selection: $retention)
              }
              Text(retentionDetail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 4)
      }
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Open FUTO Backups at login, so scheduled backups keep running", isOn: $choices.openAtLogin)
        if updater.isAvailable {
          Toggle("Check for updates automatically", isOn: $choices.checkForUpdates)
        }
      }
      .toggleStyle(.checkbox)
      .font(.system(size: 12))
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 12) {
        Button("Back Up Now") { requestFinish(backUpNow: true) }
          .buttonStyle(PrimaryButtonStyle(large: true))
          .keyboardShortcut(.defaultAction)
        Button("Not Now") { requestFinish(backUpNow: false) }
          .buttonStyle(SecondaryButtonStyle())
      }
      Button("Back", action: back)
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
    .alert("Delete old snapshots?", isPresented: confirmingBinding, presenting: pendingBackUpNow) { backUpNow in
      Button("Delete Old Snapshots", role: .destructive) { finish(backUpNow: backUpNow) }
      Button("Cancel", role: .cancel) {}
    } message: { _ in
      Text(
        "This backup \(existingHostnames == nil ? "may already have" : "already has") snapshots from this Mac. “\(retention.retention.summary)” can delete the ones it doesn't keep, starting with the first backup, and deleted snapshots can't be recovered."
      )
    }
  }

  private var confirmingBinding: Binding<Bool> {
    Binding(
      get: { pendingBackUpNow != nil },
      set: { if !$0 { pendingBackUpNow = nil } })
  }

  private var existingHostnames: [String]? {
    model.snapshotsLoad == .loaded ? model.snapshots.map(\.hostname) : nil
  }

  private func requestFinish(backUpNow: Bool) {
    if retention.retention.mayDeleteResumedSnapshots(hostnames: existingHostnames, host: model.config.host) {
      pendingBackUpNow = backUpNow
    } else {
      finish(backUpNow: backUpNow)
    }
  }

  private func finish(backUpNow: Bool) {
    pendingBackUpNow = nil
    model.setLaunchAtLogin(choices.openAtLogin)
    if updater.isAvailable, updater.automaticallyChecksForUpdates != choices.checkForUpdates {
      updater.automaticallyChecksForUpdates = choices.checkForUpdates
    }
    updater.start()
    model.finishOnboarding(folders: selection.paths, retention: retention, backUpNow: backUpNow)
  }

  private var retentionDetail: String {
    let effect =
      retention == .never
      ? "Every snapshot is kept, which uses more storage over time."
      : "Older snapshots are deleted after each backup."
    return effect + " Custom rules are in Settings."
  }

  private var foldersSummary: String {
    selection.paths.count == 1 ? "1 folder" : "\(selection.paths.count) folders"
  }

  private var sizeSummary: String {
    let total = selection.total { estimates.sizes[$0] ?? .calculating }
    if total.isCalculating { return "Calculating…" }
    return total.isPartial ? "At least \(Format.bytes(total.bytes))" : "About \(Format.bytes(total.bytes))"
  }

  private var scheduleSummary: String {
    switch model.config.schedule {
    case .manual: return "Only when you start a backup"
    case .hourly: return "Every hour"
    case .daily(let hour, let minute): return "Every day at \(time(hour: hour, minute: minute))"
    case .weekly(let weekday, let hour, let minute):
      return "Every \(Schedule.weekdayName(weekday, calendar: .current)) at \(time(hour: hour, minute: minute))"
    }
  }

  private func time(hour: Int, minute: Int) -> String {
    let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    return date.formatted(date: .omitted, time: .shortened)
  }
}

private struct SummaryRow<Detail: View>: View {
  let systemName: String
  let tint: Color
  let title: String
  let value: String
  @ViewBuilder var detail: Detail

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      IconTile(systemName: systemName, tint: tint)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
          Spacer()
          Text(value)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        detail
      }
    }
  }
}
