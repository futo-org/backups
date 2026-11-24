import AppKit
import BackupsCore
import SwiftUI

struct WelcomeView: View {
  @Environment(AppModel.self) private var model
  @State private var showServer = false

  var body: some View {
    ZStack {
      OnboardingBackground()
      VStack(spacing: 0) {
        Spacer(minLength: 24)
        AppGlyph(size: 96)
          .padding(.bottom, 26)
        Wordmark(height: 40)
        Text("Automatic, end-to-end encrypted backups of the folders you care about.")
          .font(.system(size: 15))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 380)
          .padding(.top, 8)
        loginState
          .padding(.top, 34)
          .frame(minHeight: 200, alignment: .top)
        Spacer(minLength: 24)
        Button {
          showServer = true
        } label: {
          Label(model.config.serverDisplayName, systemImage: "server.rack")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showServer, arrowEdge: .top) {
          ServerEditor()
            .padding(18)
            .frame(width: 380)
        }
        .padding(.bottom, 22)
      }
      .padding(.horizontal, 40)
    }
  }

  @ViewBuilder
  private var loginState: some View {
    switch model.login {
    case .idle:
      VStack(spacing: 14) {
        Button("Sign In") { model.startLogin() }
          .buttonStyle(PrimaryButtonStyle(large: true))
          .keyboardShortcut(.defaultAction)
        Text("You'll approve this Mac in your browser.")
          .font(.system(size: 12))
          .foregroundStyle(.tertiary)
      }
    case .waiting(let userCode, let url):
      VStack(spacing: 18) {
        Text("Confirm this code in your browser")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)
        DeviceCode(code: userCode)
        HStack(spacing: 10) {
          Button("Open Browser") {
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
          }
          .buttonStyle(PrimaryButtonStyle())
          Button("Copy Code") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(userCode, forType: .string)
          }
          .buttonStyle(SecondaryButtonStyle())
        }
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Waiting for approval…")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
          Button("Cancel") { model.cancelLogin() }
            .buttonStyle(.link)
            .font(.system(size: 12))
        }
      }
    case .finishing:
      VStack(spacing: 14) {
        ProgressView()
          .controlSize(.regular)
        Text("Setting up your encrypted backup…")
          .foregroundStyle(.secondary)
      }
    case .failed(let message):
      VStack(spacing: 14) {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
        Button("Try Again") { model.startLogin() }
          .buttonStyle(PrimaryButtonStyle(large: true))
      }
    }
  }
}

struct DeviceCode: View {
  let code: String

  var body: some View {
    HStack(spacing: 6) {
      ForEach(Array(code.enumerated()), id: \.offset) { _, character in
        if character == "-" {
          Capsule()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 12, height: 3)
            .padding(.horizontal, 4)
        } else {
          Text(String(character))
            .font(.system(size: 28, weight: .semibold, design: .monospaced))
            .frame(width: 40, height: 52)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                  RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Brand.blue.opacity(0.35), lineWidth: 1)))
        }
      }
    }
    .textSelection(.enabled)
  }
}

struct ServerEditor: View {
  @Environment(AppModel.self) private var model
  @State private var draft = ""
  @State private var invalid = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Server")
        .font(.headline)
      TextField("Server URL", text: $draft, prompt: Text("https://…/.well-known/yucca.json"))
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .onSubmit(apply)
      if invalid {
        Text("Enter a valid http(s) URL")
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Button("Production") { use(AppConfig.productionServerURL) }
        Button("Local dev") { use(AppConfig.devServerURL) }
        Spacer()
        Button("Apply", action: apply)
          .buttonStyle(PrimaryButtonStyle())
          .disabled(draft == model.config.serverURL.absoluteString)
      }
      Text("Changing the server signs you out.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .onAppear { draft = model.config.serverURL.absoluteString }
  }

  private func apply() {
    guard let url = URL(string: draft.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
    else {
      invalid = true
      return
    }
    use(url)
  }

  private func use(_ url: URL) {
    invalid = false
    model.setServerURL(url)
    draft = url.absoluteString
  }
}
