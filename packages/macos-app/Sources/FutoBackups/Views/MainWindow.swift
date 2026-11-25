import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
  case overview
  case folders
  case history
  case settings

  static let storageKey = "sidebarPage"

  var id: String { rawValue }

  var title: String {
    rawValue.prefix(1).uppercased() + rawValue.dropFirst()
  }

  var systemImage: String {
    switch self {
    case .overview: return "gauge.with.dots.needle.67percent"
    case .folders: return "folder"
    case .history: return "clock.arrow.circlepath"
    case .settings: return "gearshape"
    }
  }
}

struct MainWindow: View {
  @Environment(AppModel.self) private var model
  @AppStorage(SidebarItem.storageKey) private var selection: SidebarItem = .overview

  var body: some View {
    Group {
      if !model.sessionLoaded {
        LaunchView()
          .fullWindow(reservingBanner: model.configLoadFailure != nil)
      } else if model.config.telemetryConsentedAt == nil {
        TelemetryConsentView()
          .fullWindow(reservingBanner: model.configLoadFailure != nil)
      } else if model.signedIn && model.needsOnboarding {
        FirstRunOnboarding()
          .fullWindow(reservingBanner: model.configLoadFailure != nil)
      } else if model.signedIn {
        NavigationSplitView {
          sidebar
        } detail: {
          detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else if model.recoveryKeyStep != nil {
        RecoveryKeyOnboarding()
          .fullWindow(reservingBanner: model.configLoadFailure != nil)
      } else {
        WelcomeView()
          .fullWindow(reservingBanner: model.configLoadFailure != nil)
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if model.sessionLoaded && !model.signedIn, let failure = model.configLoadFailure {
        Banner(systemName: "exclamationmark.triangle.fill", tint: .orange, text: failure, copyable: true) {
          model.configLoadFailure = nil
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, 28)
        .padding(.top, 16)
      }
    }
    .frame(minWidth: 820, minHeight: 580)
  }

  private var sidebar: some View {
    List(selection: sidebarSelection) {
      ForEach(SidebarItem.allCases) { item in
        Label(item.title, systemImage: item.systemImage)
          .badge(badge(for: item))
          .tag(item)
      }
    }
    .tint(nil)
    .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    .safeAreaInset(edge: .top) {
      HStack(spacing: 8) {
        Text("FUTO Backups")
          .font(.system(size: 13, weight: .semibold, design: .rounded))
        AlphaBadge()
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 18)
      .padding(.top, 6)
      .padding(.bottom, 4)
    }
    .safeAreaInset(edge: .bottom) {
      AccountChip()
        .padding(12)
    }
  }

  @ViewBuilder
  private var detail: some View {
    VStack(spacing: 0) {
      if let text = model.setupError ?? model.lastError {
        Banner(systemName: "exclamationmark.triangle.fill", tint: .orange, text: text, copyable: true) {
          model.setupError = nil
          model.lastError = nil
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
      }
      switch selection {
      case .overview: OverviewView(showFolders: { selection = .folders }).navigationTitle("Overview")
      case .folders: FoldersView()
      case .history: HistoryView()
      case .settings: SettingsView().navigationTitle("Settings")
      }
    }
    .toolbar {
      if selection != .overview {
        ToolbarItem(placement: .primaryAction) {
          BackUpNowToolbarButton()
            .buttonStyle(.borderedProminent)
        }
      }
    }
  }

  private var sidebarSelection: Binding<SidebarItem?> {
    Binding(get: { selection }, set: { if let page = $0 { selection = page } })
  }

  private func badge(for item: SidebarItem) -> Text? {
    guard item == .overview, model.activity == .backingUp || model.activity == .restoring else { return nil }
    let progress = model.activityProgress
    if let fraction = progress.wholePercentFraction {
      return Text(fraction, format: .percent.precision(.fractionLength(0)))
    }
    guard let step = progress.restore, step.partCount > 1 else { return nil }
    return Text("\(step.part)/\(step.partCount)")
  }
}

struct AccountChip: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(Brand.gradient)
        .frame(width: 30, height: 30)
        .overlay(
          Text(initial)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(.white))
      VStack(alignment: .leading, spacing: 1) {
        Text(model.account?.email ?? "Signed in")
          .font(.system(size: 12, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        Text(model.config.serverDisplayName)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.primary.opacity(0.05)))
  }

  private var initial: String {
    String(model.account?.email.first ?? "F").uppercased()
  }
}

extension View {
  fileprivate func fullWindow(reservingBanner: Bool) -> some View {
    toolbar(removing: .title)
      .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
      .ignoresSafeArea(edges: reservingBanner ? [] : .top)
  }
}
