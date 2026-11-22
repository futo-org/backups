import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
  case overview
  case folders
  case history
  case settings

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
  @State private var selection: SidebarItem? = .overview

  var body: some View {
    Group {
      if model.signedIn {
        NavigationSplitView {
          sidebar
        } detail: {
          detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      } else {
        WelcomeView()
      }
    }
    .frame(minWidth: 820, minHeight: 580)
    .toolbar(removing: .title)
  }

  private var sidebar: some View {
    List(selection: $selection) {
      ForEach(SidebarItem.allCases) { item in
        Label(item.title, systemImage: item.systemImage)
          .badge(badge(for: item))
          .tag(item)
      }
    }
    .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    .safeAreaInset(edge: .bottom) {
      AccountChip()
        .padding(12)
    }
  }

  @ViewBuilder
  private var detail: some View {
    VStack(spacing: 0) {
      if let text = model.setupError ?? model.lastError {
        Banner(systemName: "exclamationmark.triangle.fill", tint: .orange, text: text) {
          model.setupError = nil
          model.lastError = nil
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
      }
      switch selection ?? .overview {
      case .overview: OverviewView(showFolders: { selection = .folders })
      case .folders: FoldersView()
      case .history: HistoryView()
      case .settings: SettingsView()
      }
    }
  }

  private func badge(for item: SidebarItem) -> Text? {
    guard item == .overview, case .backingUp(let progress) = model.activity else { return nil }
    return Text(progress.percentDone, format: .percent.precision(.fractionLength(0)))
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
        Text(model.config.serverURL.host() ?? "")
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
