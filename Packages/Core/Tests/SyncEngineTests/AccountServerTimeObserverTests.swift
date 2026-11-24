import Foundation
import Persistence
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `AccountServerTimeObserver`: the seam mapping an authenticated response's `TokenAccount`
/// to the single local account row and persisting the estimated server-clock offset.
@Suite struct AccountServerTimeObserverTests {

  @Test func observationForTheCurrentAccountPersistsTheOffset() async throws {
    let database = try AppDatabase.inMemory()
    let server = try ABSServerConfig(url: try #require(URL(string: "https://drain.example.test")))
    let account = try TokenAccount(credentialNamespace: "account:observer", userID: "user-1")
    let accountDAO = AccountDAO(database: database)
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "observer", credentialNamespace: "account:observer",
        serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }

    let observer = AccountServerTimeObserver(database: database)
    let receivedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let serverDate = Date(timeIntervalSince1970: 1_700_000_010)
    await observer.observeServerDate(serverDate, receivedAt: receivedAt, account: account)

    let store = ObservedServerTimeStore(database: database)
    let accountId = try #require(try accountDAO.fetch()?.id)
    #expect(try store.fetchOffset(accountId: accountId) == 10)
  }

  @Test func observationForAMismatchedAccountIsSilentlyIgnored() async throws {
    let database = try AppDatabase.inMemory()
    let server = try ABSServerConfig(url: try #require(URL(string: "https://drain.example.test")))
    let otherAccount = try TokenAccount(server: server, userID: "someone-else")
    let accountDAO = AccountDAO(database: database)
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "observer", credentialNamespace: "account:observer",
        serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }

    let observer = AccountServerTimeObserver(database: database)
    await observer.observeServerDate(
      Date(timeIntervalSince1970: 1_700_000_010), receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
      account: otherAccount)

    let store = ObservedServerTimeStore(database: database)
    let accountId = try #require(try accountDAO.fetch()?.id)
    #expect(try store.fetchOffset(accountId: accountId) == nil)
  }

  @Test func observationBeforeAnyAccountExistsIsSilentlyIgnored() async throws {
    let database = try AppDatabase.inMemory()
    let account = try TokenAccount(credentialNamespace: "account:observer", userID: "user-1")
    let observer = AccountServerTimeObserver(database: database)

    await observer.observeServerDate(
      Date(timeIntervalSince1970: 1_700_000_010), receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
      account: account)

    // Nothing to assert against a fetch beyond "did not crash", as there is no account row at all.
  }
}
