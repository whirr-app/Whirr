import Foundation
import GRDB
import Testing

@testable import Persistence

/// One cached listening-stats snapshot per account.
@Suite struct ListeningStatsSnapshotStoreTests {

  @Test("an account with no snapshot reads nil")
  func emptyReadsNil() async throws {
    let (database, accountId) = try await Self.databaseWithAccount(serverUserId: "user-1")
    let store = ListeningStatsSnapshotStore(database: database)

    let snapshot = try await store.snapshot(accountId: accountId)

    #expect(snapshot == nil)
  }

  @Test("a replaced snapshot reads back unchanged")
  func replaceReadsBack() async throws {
    let (database, accountId) = try await Self.databaseWithAccount(serverUserId: "user-1")
    let store = ListeningStatsSnapshotStore(database: database)

    try await store.replace(accountId: accountId, with: Self.sample)

    #expect(try await store.snapshot(accountId: accountId) == Self.sample)
  }

  @Test("a second replace overwrites the first whole")
  func replaceOverwrites() async throws {
    let (database, accountId) = try await Self.databaseWithAccount(serverUserId: "user-1")
    let store = ListeningStatsSnapshotStore(database: database)
    let later = ListeningStatsSnapshot(
      fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), totalSeconds: 5, days: [], weekdaySeconds: [:],
      titles: [])

    try await store.replace(accountId: accountId, with: Self.sample)
    try await store.replace(accountId: accountId, with: later)

    #expect(try await store.snapshot(accountId: accountId) == later)
    let rows = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningStatsSnapshot") ?? -1
    }
    #expect(rows == 1)
  }

  @Test("snapshots are isolated between accounts")
  func isolatedBetweenAccounts() async throws {
    let (database, first) = try await Self.databaseWithAccount(serverUserId: "user-1")
    let second = try await database.writeAsync { db -> Int64 in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-2", serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
    let store = ListeningStatsSnapshotStore(database: database)

    try await store.replace(accountId: first, with: Self.sample)

    #expect(try await store.snapshot(accountId: second) == nil)
  }

  @Test("an unreadable stored payload reads as no snapshot rather than throwing")
  func corruptPayloadReadsNil() async throws {
    let (database, accountId) = try await Self.databaseWithAccount(serverUserId: "user-1")
    let store = ListeningStatsSnapshotStore(database: database)
    try await store.replace(accountId: accountId, with: Self.sample)
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE listeningStatsSnapshot SET daysJSON = 'not json'")
    }

    #expect(try await store.snapshot(accountId: accountId) == nil)
  }

  @Test("removing the account removes its snapshot")
  func cascadesOnAccountRemoval() async throws {
    let (database, accountId) = try await Self.databaseWithAccount(serverUserId: "user-1")
    let store = ListeningStatsSnapshotStore(database: database)
    try await store.replace(accountId: accountId, with: Self.sample)

    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
    }

    let rows = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningStatsSnapshot") ?? -1
    }
    #expect(rows == 0)
  }

  private static let sample = ListeningStatsSnapshot(
    fetchedAt: Date(timeIntervalSince1970: 1_793_885_230),
    totalSeconds: 3165.5,
    days: [
      .init(date: "2026-11-04", seconds: 600),
      .init(date: "2026-11-05", seconds: 420.5),
    ],
    weekdaySeconds: [4: 600, 5: 420.5],
    titles: [
      .init(serverItemId: "item-1", title: "Stats Fixture Book", author: "Ada Fixture", seconds: 2220),
      .init(serverItemId: "item-2", title: nil, author: nil, seconds: 945),
    ])

  private static func databaseWithAccount(serverUserId: String) async throws
    -> (database: AppDatabase, accountId: Int64)
  {
    let database = try AppDatabase.inMemory()
    let accountId = try await database.writeAsync { db -> Int64 in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: serverUserId, serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
    return (database, accountId)
  }
}
