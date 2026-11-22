import CryptoKit
import Foundation
import Security

public enum RepositoryKeysError: Error, Equatable, Sendable {
  case invalidMasterKey
}

public enum RepositoryKeys {
  public static func generateMasterKey() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      fatalError("SecRandomCopyBytes failed")
    }
    return hexString(bytes)
  }

  public static func isValidMasterKey(_ hex: String) -> Bool {
    guard hex.count == 64 else { return false }
    return hex.allSatisfy { $0.isASCII && $0.isHexDigit }
  }

  public static func normalizedMasterKey(_ input: String) -> String? {
    let compact = String(input.filter { !$0.isWhitespace && $0 != "-" }).lowercased()
    return isValidMasterKey(compact) ? compact : nil
  }

  public static func matches(_ input: String, masterKey: String) -> Bool {
    normalizedMasterKey(input) == masterKey.lowercased()
  }

  public static func displayLines(_ masterKey: String) -> [String] {
    let characters = Array(masterKey.uppercased())
    return stride(from: 0, to: characters.count, by: 16).map { lineStart in
      stride(from: lineStart, to: min(lineStart + 16, characters.count), by: 4).map { groupStart in
        String(characters[groupStart..<min(groupStart + 4, characters.count)])
      }
      .joined(separator: " ")
    }
  }

  public static func password(masterKey: String, repositoryId: String) throws -> String {
    guard isValidMasterKey(masterKey), let bytes = bytes(fromHex: masterKey) else {
      throw RepositoryKeysError.invalidMasterKey
    }
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: Data(bytes)),
      salt: Data(count: 32),
      info: Data("repository-\(repositoryId)".utf8),
      outputByteCount: 32
    )
    return hexString(derived.withUnsafeBytes { Array($0) })
  }

  private static func bytes(fromHex hex: String) -> [UInt8]? {
    var nibbles: [UInt8] = []
    nibbles.reserveCapacity(64)
    for character in hex {
      guard character.isASCII, let nibble = character.hexDigitValue else { return nil }
      nibbles.append(UInt8(nibble))
    }
    guard nibbles.count == 64 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(32)
    var index = 0
    while index < 64 {
      bytes.append(nibbles[index] << 4 | nibbles[index + 1])
      index += 2
    }
    return bytes
  }

  private static func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }
}
