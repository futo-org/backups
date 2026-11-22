import BackupsCore
import Foundation
import Testing

private let testVectorMasterKey = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"
private let testVectorRepositoryId = "0b6a1f6e-3c1d-4c2a-9f7e-5d4b3a2c1e0f"
private let testVectorPassword = "9098804fe7a3943840f958fe8d7715cf7806b26f846e1bc977a52569fdb0bf5f"

@Test("password matches the orchestration-api test vector")
func testVector() throws {
  #expect(RepositoryKeys.isValidMasterKey(testVectorMasterKey))
  let password = try RepositoryKeys.password(masterKey: testVectorMasterKey, repositoryId: testVectorRepositoryId)
  #expect(password == testVectorPassword)
}

@Test("uppercase master key derives the same password")
func uppercaseMasterKey() throws {
  #expect(RepositoryKeys.isValidMasterKey(testVectorMasterKey.uppercased()))
  let lower = try RepositoryKeys.password(masterKey: testVectorMasterKey, repositoryId: testVectorRepositoryId)
  let upper = try RepositoryKeys.password(
    masterKey: testVectorMasterKey.uppercased(), repositoryId: testVectorRepositoryId)
  #expect(upper == lower)
}

@Test("generated master key is 64 lowercase hex characters and valid")
func generatedKeyIsValid() {
  let key = RepositoryKeys.generateMasterKey()
  #expect(key.count == 64)
  #expect(key == key.lowercased())
  #expect(key.allSatisfy { $0.hexDigitValue != nil })
  #expect(RepositoryKeys.isValidMasterKey(key))
}

@Test("generated master keys differ")
func generatedKeysDiffer() {
  var keys = Set<String>()
  for _ in 0..<3 {
    keys.insert(RepositoryKeys.generateMasterKey())
  }
  #expect(keys.count == 3)
}

@Test(
  "invalid master keys are rejected",
  arguments: [
    String(repeating: "a", count: 63),
    String(repeating: "a", count: 65),
    String(repeating: "g", count: 64),
    "",
  ])
func invalidMasterKeys(hex: String) {
  #expect(!RepositoryKeys.isValidMasterKey(hex))
  #expect(throws: RepositoryKeysError.invalidMasterKey) {
    _ = try RepositoryKeys.password(masterKey: hex, repositoryId: testVectorRepositoryId)
  }
}
