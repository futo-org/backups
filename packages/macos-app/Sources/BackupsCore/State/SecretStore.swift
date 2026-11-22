import Foundation
import Security

public enum SecretKey: String, Sendable, CaseIterable {
  case accessToken = "access-token"
  case masterKey = "master-key"
}

public protocol SecretStore: Sendable {
  func get(_ key: SecretKey) throws -> String?
  func set(_ value: String, for key: SecretKey) throws
  func delete(_ key: SecretKey) throws
}

public enum SecretStoreError: Error, Equatable, Sendable {
  case keychain(Int32)
}

public struct KeychainSecretStore: SecretStore {
  private let service: String

  public init(service: String = "org.futo.backups.mac") {
    self.service = service
  }

  public func get(_ key: SecretKey) throws -> String? {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw SecretStoreError.keychain(status)
    }
    guard let data = item as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  public func set(_ value: String, for key: SecretKey) throws {
    let data = Data(value.utf8)
    let query = baseQuery(key)
    let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw SecretStoreError.keychain(updateStatus)
    }
    var addQuery = query
    addQuery[kSecValueData as String] = data
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw SecretStoreError.keychain(addStatus)
    }
  }

  public func delete(_ key: SecretKey) throws {
    let status = SecItemDelete(baseQuery(key) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SecretStoreError.keychain(status)
    }
  }

  private func baseQuery(_ key: SecretKey) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key.rawValue,
    ]
  }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [SecretKey: String]

  public init(_ values: [SecretKey: String] = [:]) {
    self.values = values
  }

  public func get(_ key: SecretKey) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[key]
  }

  public func set(_ value: String, for key: SecretKey) throws {
    lock.lock()
    defer { lock.unlock() }
    values[key] = value
  }

  public func delete(_ key: SecretKey) throws {
    lock.lock()
    defer { lock.unlock() }
    values.removeValue(forKey: key)
  }
}
