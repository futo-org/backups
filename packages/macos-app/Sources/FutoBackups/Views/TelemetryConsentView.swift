import AppKit
import SwiftUI

struct TelemetryConsentView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    ZStack {
      OnboardingBackground()
      VStack(spacing: 0) {
        Spacer(minLength: 24)
        AppGlyph(size: 96)
          .padding(.bottom, 26)
        Text("Telemetry required for closed beta")
          .font(.system(size: 22, weight: .bold, design: .rounded))
          .multilineTextAlignment(.center)
          .padding(.bottom, 22)
        Card {
          VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
              IconTile(systemName: "chart.bar.xaxis", tint: Brand.blue)
              Text(
                "FUTO Backups collects usage and diagnostic data to learn how people use it and to find problems."
              )
              .font(.system(size: 13))
              .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 12) {
              IconTile(systemName: "eye.slash", tint: .green)
              Text(
                "FUTO Backups never collects your photos, files or recovery key, and they never leave your device unencrypted."
              )
              .font(.system(size: 13))
              .fixedSize(horizontal: false, vertical: true)
            }
          }
          .padding(.vertical, 4)
        }
        .frame(maxWidth: 460)
        HStack(spacing: 12) {
          Button("Continue") { model.grantTelemetryConsent() }
            .buttonStyle(.borderedProminent)
            .tint(Brand.fill)
            .keyboardShortcut(.defaultAction)
          Button("Quit") { NSApp.terminate(nil) }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(.top, 28)
        Spacer(minLength: 24)
      }
      .padding(.horizontal, 40)
    }
  }
}
