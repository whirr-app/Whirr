import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The per-account observed-server-clock-offset store `OutboxDrainer` reads at upload time to
/// compute `estimatedServerNow`.
@Suite struct ObservedServerTimeStoreTests {

  @Test func offsetRoundTripsAcrossReopen() async throws {
    try await withOnDiskDatabases { scope in
      let url = scope.url()
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      let accountId = try await insertAccount(database)
      let store = ObservedServerTimeStore(database: database)
      try store.recordObservation(
        accountId: accountId, offsetSeconds: 12.5,
        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
      scope.close(database)

      let reopened = try scope.open(at: url, fileAttributes: FakeFileAttributeApplying())
      let reopenedStore = ObservedServerTimeStore(database: reopened)
      #expect(try reopenedStore.fetchOffset(accountId: accountId) == 12.5)
    }
  }

  @Test func aNewerObservationReplacesAnOlderOneAtomically() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await insertAccount(database)
    let store = ObservedServerTimeStore(database: database)

    try store.recordObservation(
      accountId: accountId, offsetSeconds: 5, observedAt: Date(timeIntervalSince1970: 1_000))
    try store.recordObservation(
      accountId: accountId, offsetSeconds: 9, observedAt: Date(timeIntervalSince1970: 2_000))

    #expect(try store.fetchOffset(accountId: accountId) == 9)
  }

  @Test func aStaleObservationArrivingLateNeverRegressesTheStoredOffset() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await insertAccount(database)
    let store = ObservedServerTimeStore(database: database)

    try store.recordObservation(
      accountId: accountId, offsetSeconds: 9, observedAt: Date(timeIntervalSince1970: 2_000))
    // A straggler response for an earlier moment arrives after a fresher one has landed. It must
    // never regress the stored value.
    try store.recordObservation(
      accountId: accountId, offsetSeconds: 5, observedAt: Date(timeIntervalSince1970: 1_000))

    #expect(try store.fetchOffset(accountId: accountId) == 9)
  }

  @Test func noObservationYetReportsNilRatherThanZero() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await insertAccount(database)
    let store = ObservedServerTimeStore(database: database)

    #expect(try store.fetchOffset(accountId: accountId) == nil)
  }

  // MARK: - Helpers

  private func insertAccount(_ database: AppDatabase) async throws -> Int64 {
    try await database.writeAsync { db in
      var account = PersistenceFixtures.account(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
  }

}
