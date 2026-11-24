import BackupsCore
import Foundation
import Testing

@Test("in-memory store get, set, overwrite, delete")
func inMemoryStore() throws {
  let store = InMemorySecretStore([.accessToken: "seed"])
  #expect(try store.get(.accessToken) == "seed")
  #expect(try store.get(.masterKey) == nil)
  try store.set("master", for: .masterKey)
  #expect(try store.get(.masterKey) == "master")
  try store.set("overwritten", for: .masterKey)
  #expect(try store.get(.masterKey) == "overwritten")
  try store.delete(.masterKey)
  #expect(try store.get(.masterKey) == nil)
  #expect(throws: Never.self) {
    try store.delete(.masterKey)
  }
}

@Test(
  "keychain set, overwrite, get, delete",
  .enabled(if: ProcessInfo.processInfo.environment["FUTO_BACKUPS_KEYCHAIN_TESTS"] == "1"))
func keychainStore() throws {
  let store = KeychainSecretStore(service: "org.futo.backups.mac.tests-\(UUID().uuidString)")
  defer {
    try? store.delete(.accessToken)
    try? store.delete(.masterKey)
  }
  #expect(try store.get(.accessToken) == nil)
  try store.set("token-1", for: .accessToken)
  #expect(try store.get(.accessToken) == "token-1")
  try store.set("token-2", for: .accessToken)
  #expect(try store.get(.accessToken) == "token-2")
  try store.set("master-value", for: .masterKey)
  #expect(try store.get(.masterKey) == "master-value")
  try store.delete(.accessToken)
  #expect(try store.get(.accessToken) == nil)
  #expect(throws: Never.self) {
    try store.delete(.accessToken)
  }
}
