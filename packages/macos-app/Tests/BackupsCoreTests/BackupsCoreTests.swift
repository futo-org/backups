import Testing

@testable import BackupsCore

@Test func versionIsSet() {
  #expect(!BackupsCore.version.isEmpty)
}
