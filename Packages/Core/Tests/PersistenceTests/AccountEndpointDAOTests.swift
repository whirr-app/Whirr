import Foundation
import Testing

@testable import Persistence

@Suite struct AccountEndpointDAOTests {
  @Test func fetchInsertAndDeduplicateInOrder() throws {
    let database = try AppDatabase.inMemory()
    let accountId = try makeAccount(in: database)
    let dao = AccountEndpointDAO(database: database)

    let first = try dao.insert(accountId: accountId, normalizedURL: "https://one.example", preferred: false)
    let second = try dao.insert(accountId: accountId, normalizedURL: "https://two.example", preferred: false)
    #expect(first.sortOrder == 0)
    #expect(second.sortOrder == 1)
    #expect(first.isPreferred)
    #expect(
      try dao.fetchAll(accountId: accountId).map(\.normalizedURL) == [
        "https://one.example", "https://two.example",
      ])
    #expect(throws: AccountEndpointDAOError.duplicateURL) {
      _ = try dao.insert(accountId: accountId, normalizedURL: "https://one.example", preferred: false)
    }
  }

  @Test func preferredIsExclusiveAndCanBeChanged() throws {
    let database = try AppDatabase.inMemory()
    let accountId = try makeAccount(in: database)
    let dao = AccountEndpointDAO(database: database)
    _ = try dao.insert(accountId: accountId, normalizedURL: "https://one.example", preferred: true)
    let second = try dao.insert(accountId: accountId, normalizedURL: "https://two.example", preferred: true)

    #expect(try dao.fetchAll(accountId: accountId).filter(\.isPreferred).map(\.id) == [second.id])
    try dao.setPreferred(id: try #require(second.id))
    #expect(try dao.fetchAll(accountId: accountId).filter(\.isPreferred).map(\.id) == [second.id])
  }

  @Test func reorderAndRemoveRenumberTheOrder() throws {
    let database = try AppDatabase.inMemory()
    let accountId = try makeAccount(in: database)
    let dao = AccountEndpointDAO(database: database)
    let first = try dao.insert(accountId: accountId, normalizedURL: "https://one.example", preferred: true)
    let second = try dao.insert(accountId: accountId, normalizedURL: "https://two.example", preferred: false)
    let third = try dao.insert(accountId: accountId, normalizedURL: "https://three.example", preferred: false)
    try dao.reorder(
      accountId: accountId,
      ids: [try #require(third.id), try #require(first.id), try #require(second.id)])
    #expect(try dao.fetchAll(accountId: accountId).map(\.id) == [third.id, first.id, second.id])

    try dao.remove(id: try #require(second.id))
    let remaining = try dao.fetchAll(accountId: accountId)
    #expect(remaining.map(\.sortOrder) == [0, 1])
    #expect(remaining.map(\.id) == [third.id, first.id])
    #expect(throws: AccountEndpointDAOError.reorderMismatch) {
      try dao.reorder(accountId: accountId, ids: [try #require(first.id)])
    }
  }

  @Test func refusesLastAndActiveEndpointRemoval() throws {
    let database = try AppDatabase.inMemory()
    let accountId = try makeAccount(in: database)
    let dao = AccountEndpointDAO(database: database)
    let first = try dao.insert(accountId: accountId, normalizedURL: "https://one.example", preferred: true)
    #expect(throws: AccountEndpointDAOError.cannotRemoveLastEndpoint) {
      try dao.remove(id: try #require(first.id))
    }

    _ = try dao.insert(accountId: accountId, normalizedURL: "https://two.example", preferred: false)
    #expect(throws: AccountEndpointDAOError.cannotRemoveActiveEndpoint) {
      try dao.remove(id: try #require(first.id))
    }
  }

  @Test func setActiveRequiresKnownURLAndUpdatesTheAccount() throws {
    let database = try AppDatabase.inMemory()
    let accountId = try makeAccount(in: database)
    let dao = AccountEndpointDAO(database: database)
    _ = try dao.insert(accountId: accountId, normalizedURL: "https://one.example", preferred: true)
    _ = try dao.insert(accountId: accountId, normalizedURL: "https://two.example", preferred: false)

    #expect(throws: AccountEndpointDAOError.endpointNotFound) {
      try dao.setActive(accountId: accountId, normalizedURL: "https://unknown.example")
    }
    try dao.setActive(accountId: accountId, normalizedURL: "https://two.example")
    #expect(try AccountDAO(database: database).fetch()?.serverBaseURL == "https://two.example")
  }

  @Test func marksReachedAndFailed() throws {
    let database = try AppDatabase.inMemory()
    let accountId = try makeAccount(in: database)
    let dao = AccountEndpointDAO(database: database)
    let endpoint = try dao.insert(accountId: accountId, normalizedURL: "https://one.example", preferred: true)
    let reached = Date(timeIntervalSince1970: 100)
    let failed = Date(timeIntervalSince1970: 200)
    try dao.markReached(id: try #require(endpoint.id), at: reached)
    try dao.markFailed(id: try #require(endpoint.id), at: failed)
    let saved = try #require(try dao.fetchAll(accountId: accountId).first)
    #expect(saved.lastReachedAt == reached)
    #expect(saved.lastFailedAt == failed)
  }

  @Test func accountDeletionCascadesEndpoints() throws {
    let database = try AppDatabase.inMemory()
    let accountId = try makeAccount(in: database)
    let dao = AccountEndpointDAO(database: database)
    _ = try dao.insert(accountId: accountId, normalizedURL: "https://one.example", preferred: true)
    try AccountDAO(database: database).delete()
    #expect(try dao.fetchAll(accountId: accountId).isEmpty)
  }

  private func makeAccount(in database: AppDatabase) throws -> Int64 {
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: UUID().uuidString,
        serverBaseURL: "https://one.example",
        serverUserId: UUID().uuidString,
        serverVersion: "1"))
    return try #require(account.id)
  }
}
