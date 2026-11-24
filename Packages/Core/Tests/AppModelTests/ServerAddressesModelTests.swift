import Foundation
import Persistence
import SyncEngine
import Testing

@testable import AppModel

@MainActor
@Suite struct ServerAddressesModelTests {
  @Test func loadMapsAddressState() async {
    let now = Date(timeIntervalSince1970: 100)
    let fake = FakeServerAddressManaging(endpoints: [
      Self.record(
        id: 1, url: "https://books.example.test:443/library", preferred: true,
        reached: now, failed: now.addingTimeInterval(-1)),
      Self.record(
        id: 2, url: "http://lan.example.test:13378", preferred: false,
        reached: nil, failed: now),
      Self.record(
        id: 3, url: "https://tail.example.test", preferred: false,
        reached: nil, failed: nil),
    ])
    let model = ServerAddressesModel(
      service: fake, activeURL: { "https://books.example.test:443/library" })

    await model.load()

    #expect(model.phase == .idle)
    let addresses = [
      "https://books.example.test:443/library", "http://lan.example.test:13378",
      "https://tail.example.test",
    ]
    #expect(model.rows.map(\.displayAddress) == addresses)
    #expect(model.rows[0].isActive)
    #expect(model.rows[0].isPreferred)
    #expect(model.rows[0].reachability == .reached)
    #expect(model.rows[1].reachability == .failed)
    #expect(model.rows[2].reachability == .unknown)
  }

  @Test func addSuccessAppendsAndMarksAdded() async {
    let fake = FakeServerAddressManaging()
    fake.addResult = .success(Self.record(id: 2, url: "https://remote.example.test"))
    let model = ServerAddressesModel(service: fake, activeURL: { "https://local.example.test" })

    await model.add(address: "https://remote.example.test", headers: [:])

    #expect(model.addState == .added)
    #expect(model.rows.map(\.id) == [2])
  }

  @Test func credentialsRequiredRequestsCredentials() async {
    let fake = FakeServerAddressManaging()
    fake.addResult = .failure(AccountEndpointError.credentialsRequired)
    let model = ServerAddressesModel(service: fake, activeURL: { nil })

    await model.add(address: "https://remote.example.test", headers: [:])

    #expect(model.addState == .needsCredentials)
  }

  @Test func everyKnownErrorHasSafeCopy() {
    let endpointErrors: [AccountEndpointError] = [
      .noAccount, .duplicateAddress, .credentialsRequired, .differentServerOrUser,
      .activeAddressUnreachable, .lastAddress, .activeAddress, .endpointNotFound,
      .reorderMismatch, .localPersistenceFailed,
    ]
    let lifecycleErrors: [AccountLifecycleError] = [
      .malformedURL, .unreachable, .tlsUntrusted, .incompatibleServer(detectedVersion: "2.0"),
      .invalidCredentials, .loginRateLimited(retryAfter: 1), .accountMismatch,
      .deviceBoundToDifferentAccount, .notAudiobookshelfServer, .localStateUnreadable,
      .keychainUnavailable, .localPersistenceFailed, .blockedByProxy, .redirected(target: nil),
    ]

    for error in endpointErrors {
      let copy = ServerAddressesCopy.message(for: error)
      #expect(copy.isEmpty == false)
      #expect(copy.contains("example.test") == false)
    }
    for error in lifecycleErrors {
      let copy = ServerAddressesCopy.message(for: error)
      #expect(copy.isEmpty == false)
      #expect(copy.contains("example.test") == false)
    }
  }

  /// The lab run (2026-11-08) showed both of these as "Could not reach this address", although
  /// the address answered at once. Each names what to change instead.
  @Test func proxyRefusalAndRedirectHaveTheirOwnCopy() throws {
    let blocked = ServerAddressesCopy.message(for: AccountLifecycleError.blockedByProxy)
    #expect(blocked.contains("headers"))
    #expect(blocked != ServerAddressesCopy.unreachable)

    let target = try #require(URL(string: "https://books.example.test:8443/status?token=abc"))
    let redirected = ServerAddressesCopy.message(for: AccountLifecycleError.redirected(target: target))
    #expect(redirected.contains("https://books.example.test:8443"))
    #expect(redirected.contains("token") == false)
    #expect(redirected.contains("/status") == false)
    #expect(ServerAddressesCopy.message(for: AccountLifecycleError.redirected(target: nil)).contains("https://"))
  }

  @Test func removeLastMapsToKeepOneMessage() async {
    let fake = FakeServerAddressManaging()
    fake.removeError = AccountEndpointError.lastAddress
    let model = ServerAddressesModel(service: fake, activeURL: { nil })

    await model.remove(id: 1)

    #expect(model.phase == .failed(ServerAddressesCopy.lastAddress))
  }

  @Test func movePersistsTheNewOrder() async {
    let fake = FakeServerAddressManaging(endpoints: [
      Self.record(id: 1, url: "https://one.example.test"),
      Self.record(id: 2, url: "https://two.example.test"),
      Self.record(id: 3, url: "https://three.example.test"),
    ])
    let model = ServerAddressesModel(service: fake, activeURL: { nil })
    await model.load()

    await model.move(from: IndexSet(integer: 0), to: 3)

    #expect(fake.reorderedIDs == [2, 3, 1])
    #expect(model.rows.map(\.id) == [2, 3, 1])
  }

  private static func record(
    id: Int64, url: String, preferred: Bool = false, reached: Date? = nil, failed: Date? = nil
  ) -> AccountEndpointRecord {
    AccountEndpointRecord(
      id: id, accountId: 1, normalizedURL: url, isPreferred: preferred, sortOrder: Int(id - 1),
      addedAt: Date(timeIntervalSince1970: 0), lastReachedAt: reached, lastFailedAt: failed)
  }
}

private final class FakeServerAddressManaging: ServerAddressManaging, @unchecked Sendable {
  var storedEndpoints: [AccountEndpointRecord]
  var addResult: Result<AccountEndpointRecord, Error> = .failure(AccountEndpointError.localPersistenceFailed)
  var removeError: Error?
  var reorderedIDs: [Int64] = []

  init(endpoints: [AccountEndpointRecord] = []) {
    storedEndpoints = endpoints
  }

  func endpoints() async throws -> [AccountEndpointRecord] { storedEndpoints }

  func add(url: URL, customHeaders: [String: String]) async throws -> AccountEndpointRecord {
    try addResult.get()
  }

  func add(
    url: URL, customHeaders: [String: String],
    credentials: AccountEndpointService.EndpointProofCredentials
  ) async throws -> AccountEndpointRecord {
    try addResult.get()
  }

  func remove(id: Int64) async throws {
    if let removeError { throw removeError }
  }

  func reorder(ids: [Int64]) async throws {
    reorderedIDs = ids
  }

  func setPreferred(id: Int64) async throws {}
}
