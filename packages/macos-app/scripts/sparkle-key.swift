import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
  fail("usage: sparkle-key.swift public | verify <file> <base64-signature> <base64-public-key>")
}

func decodeBase64(_ value: String) -> Data? {
  Data(base64Encoded: value.trimmingCharacters(in: .whitespacesAndNewlines))
}

switch arguments[1] {
case "public":
  let seedText = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  guard let seed = decodeBase64(seedText),
    let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
  else {
    fail("could not read an Ed25519 seed from stdin")
  }
  print(key.publicKey.rawRepresentation.base64EncodedString())
case "verify":
  guard arguments.count == 5,
    let signature = decodeBase64(arguments[3]),
    let publicKeyData = decodeBase64(arguments[4]),
    let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
    let contents = FileManager.default.contents(atPath: arguments[2])
  else {
    fail("usage: sparkle-key.swift verify <file> <base64-signature> <base64-public-key>")
  }
  if publicKey.isValidSignature(signature, for: contents) {
    exit(0)
  }
  print("signature does not verify")
  exit(1)
default:
  fail("usage: sparkle-key.swift public | verify <file> <base64-signature> <base64-public-key>")
}
