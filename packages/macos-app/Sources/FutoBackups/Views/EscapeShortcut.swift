import SwiftUI

extension View {
  func onEscape(_ action: @escaping () -> Void) -> some View {
    background {
      Button("Close", action: action)
        .keyboardShortcut(.cancelAction)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }
}
