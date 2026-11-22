import AppKit
import SwiftUI

enum Brand {
  static let indigo = Color(red: 0.36, green: 0.42, blue: 1.0)
  static let violet = Color(red: 0.63, green: 0.37, blue: 1.0)
  static let gradient = LinearGradient(colors: [indigo, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
  static let ringGradient = AngularGradient(colors: [indigo, violet, indigo], center: .center)
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
  var tint: Color = Brand.indigo
  var size: CGFloat = 28

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
      .fill(tint.gradient)
      .frame(width: size, height: size)
      .overlay(
        Image(systemName: systemName)
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white))
  }
}

struct AppGlyph: View {
  var size: CGFloat = 88

  var body: some View {
    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
      .fill(Brand.gradient)
      .frame(width: size, height: size)
      .overlay(
        Image(systemName: "lock.icloud.fill")
          .font(.system(size: size * 0.46, weight: .semibold))
          .foregroundStyle(.white)
          .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
      )
      .shadow(color: Brand.violet.opacity(0.35), radius: size * 0.2, y: size * 0.08)
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  var large = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: large ? 15 : 13, weight: .semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, large ? 26 : 16)
      .padding(.vertical, large ? 11 : 7)
      .background(Capsule().fill(Brand.gradient))
      .shadow(color: Brand.violet.opacity(configuration.isPressed ? 0.1 : 0.3), radius: 8, y: 3)
      .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
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
  let progress: Double?
  let busy: Bool
  let symbol: String
  let tint: Color
  var size: CGFloat = 132
  @State private var spin = false

  var body: some View {
    ZStack {
      Circle()
        .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
      if let progress {
        Circle()
          .trim(from: 0, to: max(0.02, progress))
          .stroke(Brand.ringGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.easeOut(duration: 0.4), value: progress)
        Text(progress, format: .percent.precision(.fractionLength(0)))
          .font(.system(size: size * 0.21, weight: .bold, design: .rounded))
          .monospacedDigit()
      } else if busy {
        Circle()
          .trim(from: 0, to: 0.28)
          .stroke(Brand.ringGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
          .rotationEffect(.degrees(spin ? 360 : 0))
          .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
          .onAppear { spin = true }
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
  }

  private var lineWidth: CGFloat { max(4, size * 0.075) }
}

struct PageHeader<Trailing: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 26, weight: .bold, design: .rounded))
        Text(subtitle)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      trailing
    }
  }
}

struct Banner: View {
  let systemName: String
  let tint: Color
  let text: String
  var actionTitle: String?
  var action: (() -> Void)?
  let dismiss: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemName)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tint)
      Text(text)
        .textSelection(.enabled)
        .lineLimit(3)
      Spacer(minLength: 8)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(SecondaryButtonStyle())
      }
      Button(action: dismiss) {
        Image(systemName: "xmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .background(Circle().fill(Color.primary.opacity(0.08)))
      }
      .buttonStyle(.plain)
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

  static func duration(_ seconds: Int) -> String {
    if seconds < 60 { return "under a minute left" }
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
    formatter.unitsStyle = .short
    return "\(formatter.string(from: TimeInterval(seconds)) ?? "") left"
  }

  static func abbreviatedPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}
