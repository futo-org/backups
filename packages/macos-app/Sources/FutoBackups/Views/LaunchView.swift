import SwiftUI

struct LaunchView: View {
  var body: some View {
    VStack(spacing: 18) {
      AppGlyph(size: 72)
      ProgressView()
        .controlSize(.small)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
