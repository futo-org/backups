import AppKit
import BackupsCore
import SwiftUI

struct AccountView: View {
  @Environment(AppModel.self) private var model
  @State private var serverDraft = ""

  var body: some View {
    Form {
      Section("Server") {
        TextField("Server URL", text: $serverDraft)
          .textFieldStyle(.roundedBorder)
        HStack {
          Button("Apply") { apply() }
          Button("Dev") { use(AppConfig.devServerURL) }
          Button("Production") { use(AppConfig.productionServerURL) }
        }
      }
      Section("Account") {
        if let account = model.account {
          LabeledContent("Signed in as", value: account.email)
          Button("Log out", role: .destructive) { model.logout() }
        } else {
          switch model.login {
          case .idle:
            Button("Log in") { model.startLogin() }
          case .waiting(let userCode, let url):
            LabeledContent("Code", value: userCode)
            Button("Open browser") { openInBrowser(url) }
            Button("Cancel", role: .destructive) { model.cancelLogin() }
          case .failed(let message):
            Text(message)
              .foregroundStyle(.red)
            Button("Log in again") { model.startLogin() }
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: syncDraft)
  }

  private func syncDraft() {
    serverDraft = model.config.serverURL.absoluteString
  }

  private func apply() {
    guard let url = URL(string: serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      model.lastError = "Enter a valid http(s) URL"
      return
    }
    use(url)
  }

  private func use(_ url: URL) {
    model.setServerURL(url)
    syncDraft()
  }

  private func openInBrowser(_ string: String) {
    if let url = URL(string: string) {
      NSWorkspace.shared.open(url)
    }
  }
}
