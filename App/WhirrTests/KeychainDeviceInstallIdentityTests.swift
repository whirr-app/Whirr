import ABSApi
import Foundation
import Testing

@testable import Whirr

@Suite("Keychain device install identity")
struct KeychainDeviceInstallIdentityTests {
  @Test("mints one stable token per installation and reads it back through a fresh instance")
  func tokenIsStableAcrossInstances() throws {
    let client = MemorySecItemClient()
    let first = KeychainDeviceInstallIdentity(client: client, service: "test.install-identity")
    guard case .token(let token) = first.currentToken() else {
      Issue.record("no token minted")
      return
    }
    #expect(token.isEmpty == false)
    #expect(first.currentToken() == .token(token))
    #expect(
      KeychainDeviceInstallIdentity(client: client, service: "test.install-identity").currentToken()
        == .token(token))

    try first.reset()
    guard case .token(let minted) = first.currentToken() else {
      Issue.record("no token re-minted")
      return
    }
    #expect(minted != token)
  }

  @Test("a Keychain that cannot be read reports unreadable, not absent, and mints nothing")
  func unreadableKeychainYieldsUnreadable() {
    let client = LockedSecItemClient()
    let identity = KeychainDeviceInstallIdentity(client: client, service: "test.install-identity")
    #expect(identity.currentToken() == .unreadable)
    #expect(client.addCount == 0)
  }

  @Test("a readable Keychain that cannot mint reports absent rather than a volatile token")
  func failedMintYieldsAbsent() {
    let identity = KeychainDeviceInstallIdentity(
      client: AbsentUnwritableSecItemClient(), service: "test.install-identity")
    #expect(identity.currentToken() == .absent)
  }

  @Test("a locked read is not cached, so the read after unlock returns the stored token")
  func unreadableIsRetried() throws {
    let client = LockedSecItemClient()
    let identity = KeychainDeviceInstallIdentity(client: client, service: "test.install-identity")
    #expect(identity.currentToken() == .unreadable)
    client.unlock(storing: "stored")
    #expect(identity.currentToken() == .token("stored"))
    #expect(client.addCount == 0)
  }

  @Test("the shared consent store binds to the shared install identity and starts closed")
  func compositionStartsWithoutConsent() {
    // The production defaults may carry a stale flag from a previous run; a mismatched or absent
    // token must read as no consent either way, so the gate stays closed until the listener opts in.
    #expect(PodcastCloudSyncComposition.gate.allowsCloudWork == false)
  }
}

private final class MemorySecItemClient: SecItemClient, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data] = [:]

  func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    items[query.key] = attributes.data
  }

  func update(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    items[query.key] = attributes.data
  }

  func copyData(for query: KeychainItemQuery) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return items[query.key]
  }

  func delete(for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    items.removeValue(forKey: query.key)
  }
}

/// The shape of a read before first unlock: `SecuritySecItemClient.copyData` throws a status other
/// than not-found (`errSecInteractionNotAllowed`) rather than returning `nil`.
private final class LockedSecItemClient: SecItemClient, @unchecked Sendable {
  static let interactionNotAllowed: Int32 = -25308

  private let lock = NSLock()
  private var stored: Data?
  private var isLocked = true
  private var adds = 0

  var addCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return adds
  }

  func unlock(storing token: String) {
    lock.lock()
    defer { lock.unlock() }
    isLocked = false
    stored = Data(token.utf8)
  }

  func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    adds += 1
    if isLocked { throw KeychainStoreError.keychainFailure(status: Self.interactionNotAllowed) }
    stored = attributes.data
  }

  func update(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
    try add(attributes, for: query)
  }

  func copyData(for query: KeychainItemQuery) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    if isLocked { throw KeychainStoreError.keychainFailure(status: Self.interactionNotAllowed) }
    return stored
  }

  func delete(for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    stored = nil
  }
}

/// Reads succeed and find nothing; every write fails.
private struct AbsentUnwritableSecItemClient: SecItemClient {
  struct Failure: Error {}
  func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws { throw Failure() }
  func update(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws { throw Failure() }
  func copyData(for query: KeychainItemQuery) throws -> Data? { nil }
  func delete(for query: KeychainItemQuery) throws { throw Failure() }
}
