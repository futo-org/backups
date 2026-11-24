import BackupsCore
import Charts
import SwiftUI

struct UploadSpeedCard: View {
  let speed: UploadSpeed

  var body: some View {
    Card(padding: 16) {
      HStack(alignment: .center, spacing: 20) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Upload speed")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
          if speed.hasStarted {
            Text(UploadSpeed.rateText(speed.bytesPerSecond))
              .font(.system(size: 26, weight: .semibold, design: .rounded))
              .monospacedDigit()
              .contentTransition(.numericText())
              .animation(.easeOut(duration: 0.3), value: speed.bytesPerSecond)
            Text(details)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
              .monospacedDigit()
              .lineLimit(2)
              .fixedSize(horizontal: false, vertical: true)
          } else {
            Text("Preparing upload…")
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(.secondary)
          }
        }
        .frame(minWidth: 180, alignment: .leading)
        if speed.hasStarted {
          UploadSparkline(speed: speed, interactive: true)
            .frame(height: 64)
            .frame(maxWidth: .infinity)
        } else {
          Spacer(minLength: 0)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Upload speed")
    .accessibilityValue(speed.accessibilitySummary)
  }

  private var details: String {
    var parts = ["Average \(UploadSpeed.rateText(speed.averageBytesPerSecond))"]
    if let limit = speed.throttle.activeLimit(at: Date()) {
      parts.append("limited to \(UploadSpeed.rateText(Double(limit)))")
    }
    return parts.joined(separator: " · ")
  }
}

struct UploadSpeedBadge: View {
  let speed: UploadSpeed

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "arrow.up")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
      if speed.hasStarted {
        Text(UploadSpeed.rateText(speed.bytesPerSecond))
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1)
          .fixedSize()
        UploadSparkline(speed: speed, interactive: false)
          .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
      } else {
        Text("Preparing upload…")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Upload speed")
    .accessibilityValue(speed.accessibilitySummary)
  }
}

struct UploadSparkline: View {
  let speed: UploadSpeed
  let interactive: Bool
  @State private var hoveredOffset: Double?
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let points = speed.history
    let hovered = hoveredOffset.flatMap { offset in
      points.min { abs($0.secondsAgo + offset) < abs($1.secondsAgo + offset) }
    }
    Chart {
      ForEach(Array(points.enumerated()), id: \.offset) { _, point in
        AreaMark(x: .value("Time", -point.secondsAgo), y: .value("Speed", point.bytesPerSecond))
          .interpolationMethod(.monotone)
          .foregroundStyle(
            LinearGradient(
              colors: [Brand.blue.opacity(colorScheme == .dark ? 0.4 : 0.3), Brand.blue.opacity(0)],
              startPoint: .top, endPoint: .bottom))
        LineMark(x: .value("Time", -point.secondsAgo), y: .value("Speed", point.bytesPerSecond))
          .interpolationMethod(.monotone)
          .foregroundStyle(Brand.blue)
          .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      }
      if let hovered {
        RuleMark(x: .value("Time", -hovered.secondsAgo))
          .foregroundStyle(Color.primary.opacity(0.25))
          .lineStyle(StrokeStyle(lineWidth: 1))
          .annotation(
            position: .top, spacing: 4,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            SparklineTooltip(point: hovered)
          }
        PointMark(x: .value("Time", -hovered.secondsAgo), y: .value("Speed", hovered.bytesPerSecond))
          .symbol { SparklineDot(surface: surface) }
      }
      if interactive, hovered == nil, let latest = points.last {
        PointMark(x: .value("Time", -latest.secondsAgo), y: .value("Speed", latest.bytesPerSecond))
          .symbol { SparklineDot(surface: surface) }
      }
    }
    .chartXScale(domain: -UploadSpeed.historySeconds...0)
    .chartYScale(domain: 0...speed.chartCeiling)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartLegend(.hidden)
    .chartOverlay { proxy in
      if interactive {
        GeometryReader { geometry in
          Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location):
                guard let plot = proxy.plotFrame else { return }
                let x = location.x - geometry[plot].origin.x
                hoveredOffset = proxy.value(atX: x, as: Double.self)
              case .ended:
                hoveredOffset = nil
              }
            }
        }
      }
    }
    .accessibilityHidden(true)
  }

  private var surface: Color {
    colorScheme == .dark
      ? Color(nsColor: .windowBackgroundColor).mix(with: .white, by: 0.045) : .white
  }
}

private struct SparklineDot: View {
  let surface: Color

  var body: some View {
    Circle()
      .fill(Brand.blue)
      .frame(width: 8, height: 8)
      .padding(2)
      .background(Circle().fill(surface))
  }
}

private struct SparklineTooltip: View {
  let point: UploadSpeed.Point

  var body: some View {
    HStack(spacing: 4) {
      Text(UploadSpeed.rateText(point.bytesPerSecond))
        .fontWeight(.semibold)
        .foregroundStyle(.primary)
      Text("· \(age)")
        .foregroundStyle(.secondary)
    }
    .font(.system(size: 11))
    .monospacedDigit()
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(.regularMaterial)
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    )
    .fixedSize()
  }

  private var age: String {
    let seconds = Int(point.secondsAgo.rounded())
    return seconds < 1 ? "now" : "\(seconds) s ago"
  }
}
