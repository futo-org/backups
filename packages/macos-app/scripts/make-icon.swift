import AppKit
import SwiftUI

struct IconView: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 185, style: .continuous)
        .fill(Color(red: 0.259, green: 0.349, blue: 0.722))
        .overlay(
          RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: .bottom))
        )
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.28), radius: 20, y: 12)
      ZStack {
        Image(systemName: "icloud")
          .font(.system(size: 500, weight: .bold))
        Image(systemName: "arrow.triangle.2.circlepath")
          .font(.system(size: 250, weight: .black))
          .offset(x: 4, y: 38)
      }
      .foregroundStyle(.white)
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
