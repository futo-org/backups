// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FutoBackupsMac",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "FutoBackups", targets: ["FutoBackups"]),
    .library(name: "BackupsCore", targets: ["BackupsCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
  ],
  targets: [
    .target(name: "BackupsCore"),
    .executableTarget(
      name: "FutoBackups",
      dependencies: ["BackupsCore", .product(name: "Sparkle", package: "Sparkle")],
      linkerSettings: [
        .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
      ]),
    .testTarget(name: "BackupsCoreTests", dependencies: ["BackupsCore"]),
  ]
)
