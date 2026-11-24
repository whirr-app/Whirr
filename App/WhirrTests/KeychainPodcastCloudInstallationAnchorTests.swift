import ABSApi
import Foundation
import Persistence
import Testing

@testable import Whirr

@Suite("Keychain podcast cloud installation anchor")
struct KeychainPodcastCloudInstallationAnchorTests {
  private static let service = "test.podcast-cloud-installation"

  @Test("an absent item reads as definitively empty rather than as a failure")
  func absenceIsNotAnError() throws {
    let anchor = KeychainPodcastCloudInstallationAnchor(
      client: DuplicateAwareSecItemClient(), service: Self.service)
    #expect(try anchor.read() == nil)
  }

  @Test("writing is update-or-add, so a surviving item is overwritten rather than throwing")
  func writeOverwritesASurvivingItem() throws {
    let client = DuplicateAwareSecItemClient()
    let anchor = KeychainPodcastCloudInstallationAnchor(client: client, service: Self.service)
    let first = UUID()
    try anchor.write(first)
    #expect(try anchor.read() == first)
    // The reinstall case: the Keychain item outlived the database, so the fresh identity has to
    // replace it. `add` throws `itemAlreadyExists` here, exactly as the real client does.
    let second = UUID()
    try anchor.write(second)
    #expect(try anchor.read() == second)
    #expect(client.addFailures == 1)
  }

  @Test("an unreadable Keychain throws instead of imitating absence")
  func failureIsNotAbsence() {
    let anchor = KeychainPodcastCloudInstallationAnchor(
      client: FailingSecItemClient(), service: Self.service)
    #expect(throws: (any Error).self) { try anchor.read() }
  }

  @Test("unparseable stored bytes read as absence so the anchor heals on the next resolution")
  func corruptBytesReadAsAbsence() throws {
    let client = DuplicateAwareSecItemClient()
    let query = KeychainItemQuery(
      service: Self.service, account: KeychainPodcastCloudInstallationAnchor.account)
    try client.add(
      KeychainItemAttributes(
        service: query.service, account: query.account, data: Data("not-a-uuid".utf8)),
      for: query)
    let anchor = KeychainPodcastCloudInstallationAnchor(client: client, service: Self.service)
    #expect(try anchor.read() == nil)
    let healed = UUID()
    try anchor.write(healed)
    #expect(try anchor.read() == healed)
  }

  @Test("the anchor does not share the consent token's item")
  func itIsASeparateItem() throws {
    let client = DuplicateAwareSecItemClient()
    let identity = KeychainDeviceInstallIdentity(client: client, service: "test.install-identity")
    let anchor = KeychainPodcastCloudInstallationAnchor(client: client, service: Self.service)
    let installation = UUID()
    try anchor.write(installation)
    guard case .token(let token) = identity.currentToken() else {
      Issue.record("no install token minted")
      return
    }
    #expect(token != installation.uuidString)
    #expect(try anchor.read() == installation)
    #expect(
      KeychainPodcastCloudInstallationAnchor.defaultService
        != KeychainDeviceInstallIdentity.defaultService)
  }
}

/// `MemorySecItemClient` in the sibling suite silently overwrites on `add`. This one reproduces
/// the behaviour the anchor's update-or-add actually has to cope with.
private final class DuplicateAwareSecItemClient: SecItemClient, @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String: Data] = [:]
  private(set) var addFailures = 0

  func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    guard items[query.key] == nil else {
      addFailures += 1
      throw KeychainStoreError.itemAlreadyExists
    }
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

private struct FailingSecItemClient: SecItemClient {
  struct Failure: Error {}
  func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws { throw Failure() }
  func update(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws { throw Failure() }
  func copyData(for query: KeychainItemQuery) throws -> Data? { throw Failure() }
  func delete(for query: KeychainItemQuery) throws { throw Failure() }
}
