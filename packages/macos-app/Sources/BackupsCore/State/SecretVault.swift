import Foundation

public final class SecretVault: Sendable {
  private let store: any SecretStore
  private let queue: DispatchQueue

  public init(store: any SecretStore, label: String = "org.futo.backups.mac.secrets") {
    self.store = store
    self.queue = DispatchQueue(label: label)
  }

  public func get(_ key: SecretKey) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(with: Result { try self.store.get(key) })
      }
    }
  }

  public func set(_ value: String, for key: SecretKey) async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(with: Result { try self.store.set(value, for: key) })
      }
    }
  }

  public func delete(_ key: SecretKey) async throws {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        continuation.resume(with: Result { try self.store.delete(key) })
      }
    }
  }

  public func delete(_ key: SecretKey, ifEquals expected: String) async throws -> Bool {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
      queue.async {
        continuation.resume(
          with: Result {
            guard try self.store.get(key) == expected else {
              return false
            }
            try self.store.delete(key)
            return true
          })
      }
    }
  }
}
