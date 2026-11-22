import BackupsCore
import SwiftUI

private enum ScheduleMode: Hashable {
  case manual
  case hourly
  case daily
}

struct ScheduleView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Form {
      Section("Schedule") {
        Picker("Run backups", selection: modeBinding) {
          Text("Manual").tag(ScheduleMode.manual)
          Text("Hourly").tag(ScheduleMode.hourly)
          Text("Daily").tag(ScheduleMode.daily)
        }
        if case .daily = model.config.schedule {
          DatePicker("Time", selection: dailyTimeBinding, displayedComponents: .hourAndMinute)
        }
      }
      Section("Last run") {
        if let lastRun = model.config.lastRun {
          LabeledContent("Started", value: lastRun.startedAt.formatted(date: .abbreviated, time: .shortened))
          LabeledContent("Status", value: lastRun.status.rawValue.capitalized)
          if let message = lastRun.message {
            Text(message)
              .textSelection(.enabled)
          }
        } else {
          Text("Never")
            .foregroundStyle(.secondary)
        }
        LabeledContent(
          "Next run", value: model.nextRun?.formatted(date: .abbreviated, time: .shortened) ?? "Manual only")
      }
      Section("Backup") {
        if let activity = model.activity {
          Button("Cancel") { model.cancelBackup() }
          switch activity {
          case .backingUp(let progress):
            ProgressView(value: progress.percentDone)
            Text("\(progress.filesDone) of \(progress.totalFiles) files")
              .foregroundStyle(.secondary)
          case .preparing:
            Text("Preparing…")
              .foregroundStyle(.secondary)
          case .pruning:
            Text("Pruning old snapshots…")
              .foregroundStyle(.secondary)
          case .restoring:
            Text("Restoring…")
              .foregroundStyle(.secondary)
          }
        } else {
          Button("Back up now") { model.backupNow() }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var modeBinding: Binding<ScheduleMode> {
    Binding(
      get: {
        switch model.config.schedule {
        case .manual: return .manual
        case .hourly: return .hourly
        case .daily: return .daily
        }
      },
      set: { mode in
        switch mode {
        case .manual:
          model.setSchedule(.manual)
        case .hourly:
          model.setSchedule(.hourly)
        case .daily:
          if case .daily(let hour, let minute) = model.config.schedule {
            model.setSchedule(.daily(hour: hour, minute: minute))
          } else {
            model.setSchedule(.daily(hour: 12, minute: 0))
          }
        }
      })
  }

  private var dailyTimeBinding: Binding<Date> {
    Binding(
      get: {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        if case .daily(let hour, let minute) = model.config.schedule {
          components.hour = hour
          components.minute = minute
        } else {
          components.hour = 12
          components.minute = 0
        }
        return Calendar.current.date(from: components) ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        model.setSchedule(.daily(hour: components.hour ?? 12, minute: components.minute ?? 0))
      })
  }
}
