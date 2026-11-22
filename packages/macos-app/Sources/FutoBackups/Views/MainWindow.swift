import SwiftUI

private enum Section: String, CaseIterable, Identifiable {
  case account
  case folders
  case schedule
  case snapshots
  case settings

  var id: String { rawValue }

  var title: String {
    rawValue.prefix(1).uppercased() + rawValue.dropFirst()
  }

  var systemImage: String {
    switch self {
    case .account: return "person.crop.circle"
    case .folders: return "folder"
    case .schedule: return "clock"
    case .snapshots: return "clock.arrow.circlepath"
    case .settings: return "gearshape"
    }
  }
}

struct MainWindow: View {
  @Environment(AppModel.self) private var model
  @State private var selection: Section? = .account

  var body: some View {
    NavigationSplitView {
      List(Section.allCases, selection: $selection) { section in
        Label(section.title, systemImage: section.systemImage)
      }
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 260)
    } detail: {
      VStack(spacing: 0) {
        banner
        detail
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationTitle("FUTO Backups")
  }

  @ViewBuilder
  private var banner: some View {
    if let text = model.setupError ?? model.lastError {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.yellow)
        Text(text)
          .textSelection(.enabled)
        Spacer()
        Button("Dismiss") {
          model.setupError = nil
          model.lastError = nil
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity)
      .background(.red.opacity(0.12))
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch selection ?? .account {
    case .account: AccountView()
    case .folders: FoldersView()
    case .schedule: ScheduleView()
    case .snapshots: SnapshotsView()
    case .settings: SettingsView()
    }
  }
}
