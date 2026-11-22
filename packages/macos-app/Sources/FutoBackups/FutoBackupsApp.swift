import BackupsCore
import SwiftUI

@main
struct FutoBackupsApp: App {
  var body: some Scene {
    WindowGroup("FUTO Backups") {
      Text("FUTO Backups \(BackupsCore.version)")
        .padding()
    }
  }
}
