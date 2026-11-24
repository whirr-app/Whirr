import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct HiddenContinueSeriesStoreTests {

  @Test("replacing a non-empty hidden series set with an empty set clears it")
  func replacingWithEmptySetClearsRows() async throws {
    let (database, accountId) = try await Self.databaseWithAccount(serverUserId: "user-1")
    let store = HiddenContinueSeriesStore(database: database)

    try await store.replace(accountId: accountId, serverSeriesIDs: ["series-1", "series-2"])
    try await store.replace(accountId: accountId, serverSeriesIDs: [])

    let count = try await database.readAsync { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM hiddenContinueSeries WHERE accountId = ?",
        arguments: [accountId]) ?? -1
    }
    #expect(count == 0)
  }

  @Test("hidden series rows are isolated between accounts")
  func rowsAreScopedToTheirAccount() async throws {
    let database = try AppDatabase.inMemory()
    let accountIds = try await database.writeAsync { db -> (Int64, Int64) in
      var first = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try first.insert(db)
      var second = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-2", serverVersion: "2.35.1")
      try second.insert(db)
      return (first.id!, second.id!)
    }
    let store = HiddenContinueSeriesStore(database: database)

    try await store.replace(accountId: accountIds.0, serverSeriesIDs: ["shared", "first-only"])
    try await store.replace(accountId: accountIds.1, serverSeriesIDs: ["shared", "second-only"])

    let firstRows = try await database.readAsync { db in
      try String.fetchAll(
        db,
        sql: "SELECT serverSeriesId FROM hiddenContinueSeries WHERE accountId = ? ORDER BY serverSeriesId",
        arguments: [accountIds.0])
    }
    let secondRows = try await database.readAsync { db in
      try String.fetchAll(
        db,
        sql: "SELECT serverSeriesId FROM hiddenContinueSeries WHERE accountId = ? ORDER BY serverSeriesId",
        arguments: [accountIds.1])
    }
    #expect(firstRows == ["first-only", "shared"])
    #expect(secondRows == ["second-only", "shared"])
  }

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
