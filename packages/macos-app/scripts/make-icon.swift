import AppKit
import SwiftUI

struct IconView: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 185, style: .continuous)
        .fill(
          LinearGradient(
            colors: [Color(red: 0.36, green: 0.42, blue: 1.0), Color(red: 0.63, green: 0.37, blue: 1.0)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(
              LinearGradient(
                colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
        )
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.3), radius: 20, y: 12)
      Image(systemName: "lock.icloud.fill")
        .font(.system(size: 420, weight: .semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
    }
    .frame(width: 1024, height: 1024)
  }
}

@MainActor
func render(to path: String) {
  let renderer = ImageRenderer(content: IconView())
  renderer.scale = 1
  guard let image = renderer.cgImage else { fatalError("render failed") }
  let rep = NSBitmapImageRep(cgImage: image)
  try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

MainActor.assumeIsolated {
  render(to: CommandLine.arguments[1])
}
