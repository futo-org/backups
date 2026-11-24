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

@Test(
  "non-ASCII hex-like digits are rejected",
  arguments: [
    String(repeating: "１", count: 64),
    String(repeating: "٣", count: 64),
    String(testVectorMasterKey.dropLast()) + "１",
  ])
func nonASCIIMasterKeysRejected(key: String) {
  #expect(!RepositoryKeys.isValidMasterKey(key))
  #expect(RepositoryKeys.normalizedMasterKey(key) == nil)
  #expect(throws: RepositoryKeysError.invalidMasterKey) {
    _ = try RepositoryKeys.password(masterKey: key, repositoryId: testVectorRepositoryId)
  }
}

@Test(
  "normalizedMasterKey accepts the displayed and pasted forms",
  arguments: [
    testVectorMasterKey,
    testVectorMasterKey.uppercased(),
    "0011 2233 4455 6677 8899 AABB CCDD EEFF\n0011 2233 4455 6677 8899 AABB CCDD EEFF",
    "  0011-2233-4455-6677-8899-aabb-ccdd-eeff-0011-2233-4455-6677-8899-aabb-ccdd-eeff  ",
  ])
func normalizedMasterKeyAccepts(input: String) {
  #expect(RepositoryKeys.normalizedMasterKey(input) == testVectorMasterKey)
  #expect(RepositoryKeys.matches(input, masterKey: testVectorMasterKey))
}

@Test(
  "normalizedMasterKey rejects malformed keys",
  arguments: ["", "0011", String(testVectorMasterKey.dropLast()), String(testVectorMasterKey.dropLast()) + "g"])
func normalizedMasterKeyRejects(input: String) {
  #expect(RepositoryKeys.normalizedMasterKey(input) == nil)
  #expect(!RepositoryKeys.matches(input, masterKey: testVectorMasterKey))
}

@Test("a different valid key does not match")
func differentKeyDoesNotMatch() {
  #expect(!RepositoryKeys.matches(String(repeating: "a", count: 64), masterKey: testVectorMasterKey))
}

@Test("displayLines splits the key into four lines of four uppercase groups")
func displayLines() {
  #expect(
    RepositoryKeys.displayLines(testVectorMasterKey) == [
      "0011 2233 4455 6677", "8899 AABB CCDD EEFF", "0011 2233 4455 6677", "8899 AABB CCDD EEFF",
    ])
}
