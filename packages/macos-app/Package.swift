// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "FutoBackupsMac",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "FutoBackups", targets: ["FutoBackups"]),
    .library(name: "BackupsCore", targets: ["BackupsCore"]),
  ],
  targets: [
    .target(name: "BackupsCore"),
    .executableTarget(name: "FutoBackups", dependencies: ["BackupsCore"]),
    .testTarget(name: "BackupsCoreTests", dependencies: ["BackupsCore"]),
  ]
)
