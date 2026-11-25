import AppKit
import BackupsCore
import SwiftUI

private enum ScheduleMode: Hashable {
  case manual
  case hourly
  case daily
  case weekly
}

struct OverviewView: View {
  @Environment(AppModel.self) private var model
  let showFolders: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        StatusHero(progress: model.activityProgress, showFolders: showFolders)
        if model.activity == .backingUp {
          LiveUploadSpeedCard(progress: model.activityProgress)
        }
        if model.activity == nil, let skipped = model.config.lastRun?.cloudOnlySkipped {
          CloudOnlyNotice(skipped: skipped)
        }
        HStack(spacing: 14) {
          StatTile(systemName: "calendar", tint: Brand.blue, label: "Next backup", value: nextBackup)
          StatTile(
            systemName: "externaldrive.fill", tint: .teal, label: "Protected",
            value: model.snapshots.first.map { Format.bytes($0.totalBytesProcessed) } ?? "—")
          StatTile(
            systemName: "square.stack.3d.up.fill", tint: .pink, label: "Snapshots",
            value: model.snapshots.isEmpty ? "—" : "\(model.snapshots.count)")
        }
        scheduleCard
      }
      .padding(28)
      .frame(maxWidth: 820)
      .frame(maxWidth: .infinity)
    }
  }

  private var scheduleCard: some View {
    Card {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          IconTile(systemName: "clock.fill", tint: .orange)
          VStack(alignment: .leading, spacing: 2) {
            Text("Schedule")
              .font(.headline)
            Text(scheduleDescription)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
          Spacer()
          Picker("", selection: modeBinding) {
            Text("Manual").tag(ScheduleMode.manual)
            Text("Hourly").tag(ScheduleMode.hourly)
            Text("Daily").tag(ScheduleMode.daily)
            Text("Weekly").tag(ScheduleMode.weekly)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        if timeOfDay != nil {
          HStack {
            Spacer()
            if case .weekly = model.config.schedule {
              Picker("", selection: weekdayBinding) {
                ForEach(Schedule.weekdays(calendar: .current), id: \.self) { weekday in
                  Text(Schedule.weekdayName(weekday, calendar: .current)).tag(weekday)
                }
              }
              .pickerStyle(.menu)
              .labelsHidden()
              .fixedSize()
            }
            DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
              .labelsHidden()
              .fixedSize()
          }
        }
        if !model.config.folders.isEmpty {
          Divider()
          HStack(spacing: 8) {
            ForEach(model.config.folders.prefix(4), id: \.self) { folder in
              FolderPill(path: folder)
            }
            if model.config.folders.count > 4 {
              Text("+\(model.config.folders.count - 4)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Edit", action: showFolders)
              .buttonStyle(.link)
              .font(.system(size: 12))
          }
        }
      }
    }
  }

  private var nextBackup: String {
    if model.activity != nil { return "Running now" }
    guard let nextRun = model.nextRun else { return "Manual" }
    return nextRun <= .now ? "Due now" : Format.relative(nextRun)
  }

  private var scheduleDescription: String {
    switch model.config.schedule {
    case .manual: return "Backups run only when you start them."
    case .hourly: return "Every hour while your Mac is awake."
    case .daily: return "Once a day. Missed backups run when your Mac wakes."
    case .weekly(let weekday, _, _):
      return "Every \(Schedule.weekdayName(weekday, calendar: .current)). Missed backups run when your Mac wakes."
    }
  }

  private var today: Int {
    Calendar.current.component(.weekday, from: Date())
  }

  private var timeOfDay: (hour: Int, minute: Int)? {
    switch model.config.schedule {
    case .manual, .hourly: return nil
    case .daily(let hour, let minute), .weekly(_, let hour, let minute): return (hour, minute)
    }
  }

  private var modeBinding: Binding<ScheduleMode> {
    Binding(
      get: {
        switch model.config.schedule {
        case .manual: return .manual
        case .hourly: return .hourly
        case .daily: return .daily
        case .weekly: return .weekly
        }
      },
      set: { mode in
        switch mode {
        case .manual:
          model.setSchedule(.manual)
        case .hourly:
          model.setSchedule(.hourly)
        case .daily:
          let time = timeOfDay ?? (12, 0)
          model.setSchedule(.daily(hour: time.hour, minute: time.minute))
        case .weekly:
          if case .weekly = model.config.schedule { return }
          let time = timeOfDay ?? (12, 0)
          model.setSchedule(.weekly(weekday: today, hour: time.hour, minute: time.minute))
        }
      })
  }

  private var weekdayBinding: Binding<Int> {
    Binding(
      get: {
        guard case .weekly(let weekday, _, _) = model.config.schedule else { return today }
        return weekday
      },
      set: { weekday in
        guard case .weekly(_, let hour, let minute) = model.config.schedule else { return }
        model.setSchedule(.weekly(weekday: weekday, hour: hour, minute: minute))
      })
  }

  private var timeBinding: Binding<Date> {
    Binding(
      get: {
        guard let time = timeOfDay else { return Date() }
        return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        let hour = components.hour ?? 12
        let minute = components.minute ?? 0
        switch model.config.schedule {
        case .weekly(let weekday, _, _):
          model.setSchedule(.weekly(weekday: weekday, hour: hour, minute: minute))
        case .manual, .hourly, .daily:
          model.setSchedule(.daily(hour: hour, minute: minute))
        }
      })
  }
}

struct StatusHero: View {
  @Environment(AppModel.self) private var model
  let progress: ActivityProgressStore
  let showFolders: () -> Void

  var body: some View {
    let status = StatusSummary(model: model, progress: progress.progress, restore: progress.restore)
    HStack(spacing: 30) {
      StatusRing(
        progress: status.progress, busy: status.busy, symbol: status.symbol, tint: status.tint)
      VStack(alignment: .leading, spacing: 8) {
        Text(status.title)
          .font(.system(size: 28, weight: .bold, design: .rounded))
        Text(status.subtitle)
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .copyable(status.subtitle)
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 10) {
          switch status.action {
          case .backUp:
            Button {
              model.backupNow()
            } label: {
              Label("Back Up Now", systemImage: "arrow.up.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.fill)
          case .addFolders:
            Button {
              showFolders()
            } label: {
              Label("Add Folders", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.fill)
          case .cancel:
            Button("Cancel") { model.cancelBackup() }
              .buttonStyle(.bordered)
          case .none:
            EmptyView()
          }
          if model.activity == nil, let warnings = model.config.lastRun?.warnings {
            BackupWarningsButton(warnings: warnings)
          }
        }
        .controlSize(.extraLarge)
        .padding(.top, 10)
      }
      Spacer(minLength: 0)
    }
    .padding(28)
    .background(
      ZStack {
        CardBackground()
        RadialGradient(
          colors: [status.tint.opacity(0.18), .clear], center: .topLeading, startRadius: 0, endRadius: 380)
      }
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)))
  }
}

struct LiveUploadSpeedCard: View {
  let progress: ActivityProgressStore

  var body: some View {
    if let speed = progress.speed {
      UploadSpeedCard(speed: speed)
    }
  }
}

struct StatTile: View {
  let systemName: String
  let tint: Color
  let label: String
  let value: String

  var body: some View {
    Card(padding: 16) {
      HStack(spacing: 12) {
        IconTile(systemName: systemName, tint: tint, size: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text(label)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
          Text(value)
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
      }
    }
  }
}

struct FolderPill: View {
  let path: String

  var body: some View {
    HStack(spacing: 6) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: path))
        .resizable()
        .frame(width: 16, height: 16)
      Text(URL(fileURLWithPath: path).lastPathComponent)
        .font(.system(size: 12, weight: .medium))
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(Capsule().fill(Color.primary.opacity(0.06)))
    .help(path)
  }
}
