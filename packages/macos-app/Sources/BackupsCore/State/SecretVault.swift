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
}
