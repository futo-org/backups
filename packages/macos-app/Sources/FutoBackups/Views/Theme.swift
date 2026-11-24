import AppKit
import BackupsCore
import SwiftUI

enum Brand {
  static let blue = Color(
    nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0.49, green: 0.58, blue: 0.94, alpha: 1)
        : NSColor(srgbRed: 0.259, green: 0.349, blue: 0.722, alpha: 1)
    })
  static let logo = Color(red: 0.259, green: 0.349, blue: 0.722)
  static let deep = Color(red: 0.2, green: 0.27, blue: 0.6)
  static let gradient = LinearGradient(
    colors: [Color(red: 0.34, green: 0.44, blue: 0.84), Color(red: 0.23, green: 0.31, blue: 0.65)],
    startPoint: .topLeading, endPoint: .bottomTrailing)
  static let ringGradient = AngularGradient(
    colors: [
      Color(red: 0.34, green: 0.44, blue: 0.84), Color(red: 0.45, green: 0.62, blue: 1.0),
      Color(red: 0.34, green: 0.44, blue: 0.84),
    ],
    center: .center)
}

struct Card<Content: View>: View {
  var padding: CGFloat = 18
  @ViewBuilder var content: Content

  var body: some View {
    content
      .padding(padding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(CardBackground())
  }
}

struct CardBackground: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(colorScheme == .dark ? Color.white.opacity(0.045) : Color.white)
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 1)
      )
      .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.05), radius: 6, y: 2)
  }
}

struct IconTile: View {
  let systemName: String
  var tint: Color = Brand.blue
  var size: CGFloat = 28

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
      .fill(tint.gradient)
      .frame(width: size, height: size)
      .overlay(
        Image(systemName: systemName)
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      )
      .accessibilityHidden(true)
  }
}

struct AppGlyph: View {
  var size: CGFloat = 88

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
      .fill(Brand.logo)
      .frame(width: size, height: size)
      .overlay(LogoMark(size: size))
      .shadow(color: Brand.logo.opacity(0.35), radius: size * 0.18, y: size * 0.07)
      .accessibilityHidden(true)
  }
}

struct LogoMark: View {
  let size: CGFloat

  var body: some View {
    ZStack {
      Image(systemName: "icloud")
        .font(.system(size: size * 0.55, weight: .bold))
      Image(systemName: "arrow.triangle.2.circlepath")
        .font(.system(size: size * 0.275, weight: .black))
        .offset(x: size * 0.005, y: size * 0.042)
    }
    .foregroundStyle(.white)
  }
}

struct Wordmark: View {
  var height: CGFloat = 40
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    if let image = NSImage(named: colorScheme == .dark ? "Wordmark-dark" : "Wordmark") {
      Image(nsImage: image)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(height: height)
        .accessibilityLabel("FUTO Backups")
    } else {
      Text("FUTO Backups")
        .font(.system(size: height * 0.85, weight: .bold, design: .rounded))
    }
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  var large = false
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: large ? 15 : 13, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, large ? 26 : 16)
      .padding(.vertical, large ? 11 : 7)
      .background(Capsule().fill(Brand.gradient))
      .shadow(color: Brand.deep.opacity(configuration.isPressed ? 0.1 : 0.3), radius: 8, y: 3)
      .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .contentShape(Capsule())
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  var tint: Color = .primary
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 14)
      .padding(.vertical, 7)
      .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08)))
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(Capsule())
  }
}

struct StatusRing: View {
  let title: String
  let progress: Double?
  let busy: Bool
  let symbol: String
  let tint: Color
  var size: CGFloat = 132
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
      if let progress {
        Circle()
          .trim(from: 0, to: max(0.02, progress))
          .stroke(Brand.ringGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
        Text(progress.wholePercentFraction, format: .percent.precision(.fractionLength(0)))
          .font(.system(size: size * 0.21, weight: .bold, design: .rounded))
          .monospacedDigit()
      } else if busy {
        if reduceMotion {
          busyArc
            .rotationEffect(.degrees(-90))
        } else {
          TimelineView(.animation) { timeline in
            busyArc
              .rotationEffect(
                .degrees(timeline.date.timeIntervalSinceReferenceDate.remainder(dividingBy: 1.1) / 1.1 * 360))
          }
        }
        Image(systemName: symbol)
          .font(.system(size: size * 0.26, weight: .semibold))
          .foregroundStyle(Brand.gradient)
      } else {
        Circle()
          .stroke(tint.gradient, lineWidth: lineWidth)
        Circle()
          .fill(tint.opacity(0.12))
          .padding(lineWidth * 1.6)
        Image(systemName: symbol)
          .font(.system(size: size * 0.3, weight: .bold))
          .foregroundStyle(tint.gradient)
      }
    }
    .frame(width: size, height: size)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Backup status")
    .accessibilityValue(accessibilityValue)
  }

  private var accessibilityValue: String {
    guard let progress else { return title }
    return "\(title), \(progress.wholePercentFraction.formatted(.percent.precision(.fractionLength(0))))"
  }

  private var busyArc: some View {
    Circle()
      .trim(from: 0, to: 0.28)
      .stroke(Brand.ringGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
  }

  private var lineWidth: CGFloat { max(4, size * 0.075) }
}

struct AlphaBadge: View {
  var body: some View {
    Text("ALPHA")
      .font(.system(size: 10, weight: .bold, design: .rounded))
      .tracking(0.6)
      .foregroundStyle(.primary)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(Capsule().fill(Color.orange.opacity(0.15)))
      .help("This Mac app is in alpha")
  }
}

enum Clipboard {
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

extension View {
  func copyable(_ text: String) -> some View {
    textSelection(.enabled)
      .contextMenu {
        Button("Copy") { Clipboard.copy(text) }
      }
  }
}

struct Banner: View {
  let systemName: String
  let tint: Color
  let text: String
  var actionTitle: String?
  var action: (() -> Void)?
  var copyable = false
  let dismiss: () -> Void
  @State private var copied = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemName)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tint)
      Text(text)
        .copyable(text)
        .lineLimit(3)
      Spacer(minLength: 8)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(SecondaryButtonStyle())
      }
      if copyable {
        Button {
          Clipboard.copy(text)
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
          }
        } label: {
          Image(systemName: copied ? "checkmark" : "doc.on.doc")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help("Copy error")
        .accessibilityLabel(copied ? "Copied" : "Copy error")
      }
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .background(Circle().fill(Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .help("Dismiss")
      .accessibilityLabel("Dismiss")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(tint.opacity(0.12))
        .overlay(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tint.opacity(0.25), lineWidth: 1)))
  }
}

enum Format {
  static func bytes(_ value: Int64?) -> String {
    ByteCountFormatter.string(fromByteCount: value ?? 0, countStyle: .file)
  }

  static func relative(_ date: Date, inSentence: Bool = false) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    let day =
      calendar.isDateInToday(date)
      ? "Today" : calendar.isDateInTomorrow(date) ? "Tomorrow" : calendar.isDateInYesterday(date) ? "Yesterday" : nil
    if let day { return "\(inSentence ? day.lowercased() : day) at \(time)" }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
  }

  static func day(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    return date.formatted(.dateTime.weekday(.wide).month(.wide).day())
  }

  @MainActor
  static func duration(_ seconds: Int) -> String {
    if seconds < 60 { return "under a minute left" }
    let formatter = seconds >= 3600 ? hoursAndMinutes : minutes
    return "\(formatter.string(from: TimeInterval(seconds)) ?? "") left"
  }

  @MainActor private static let hoursAndMinutes = durationFormatter([.hour, .minute])
  @MainActor private static let minutes = durationFormatter([.minute])

  private static func durationFormatter(_ units: NSCalendar.Unit) -> DateComponentsFormatter {
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = units
    formatter.unitsStyle = .short
    return formatter
  }

  static func abbreviatedPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    guard path == home || path.hasPrefix(home + "/") else { return path }
    return "~" + path.dropFirst(home.count)
  }
}
