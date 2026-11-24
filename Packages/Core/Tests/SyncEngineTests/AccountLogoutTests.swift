import Foundation
import GRDB
import Persistence
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Logout: calls `ABSClient.logout`, wipes tokens even when the server call fails, and
/// runs the schema-driven DB removal. The warn-first confirmation contract is AppModel's
/// job, not tested here.
@Suite struct AccountLogoutTests {

  private let serverBaseURL = "https://books.example.test"
  private let serverUserId = "user-1"

  private func seedLoggedInAccount(
    database: AppDatabase,
    tokenStore: any TokenStoring
  ) async throws {
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "logout-uuid",
        serverBaseURL: serverBaseURL,
        serverUserId: serverUserId,
        serverVersion: "2.35.1"
      )
      try record.save(db)
    }
    let account = try AccountDAO(database: database).fetch()!
    let tokens = TokenPair(accessToken: "access", refreshToken: "refresh")
    try tokenStore.save(tokens, for: try account.credentialTokenAccount)
    try tokenStore.save(
      tokens,
      for: try TokenAccount(
        serverURL: try account.activeServerURL, userID: account.serverUserId))
  }

  @Test func successfulLogoutClearsTokensAndRemovesTheAccountRow() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    try await seedLoggedInAccount(database: database, tokenStore: tokenStore)
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/logout", response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    let service = makeAccountLifecycleService(transport: transport, database: database, tokenStore: tokenStore)

    try await service.logout()

    let account = try TokenAccount(credentialNamespace: "account:logout-uuid", userID: serverUserId)
    let legacy = try TokenAccount(serverURL: URL(string: serverBaseURL)!, userID: serverUserId)
    #expect(try tokenStore.load(for: account) == nil)
    #expect(try tokenStore.load(for: legacy) == nil)
    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == nil)
    #expect(service.isAuthenticated == false)
  }

  @Test func serverLogoutFailureStillWipesTokensAndRemovesTheAccountRow() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    try await seedLoggedInAccount(database: database, tokenStore: tokenStore)
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/logout", response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    let service = makeAccountLifecycleService(transport: transport, database: database, tokenStore: tokenStore)

    try await service.logout()

    let account = try TokenAccount(credentialNamespace: "account:logout-uuid", userID: serverUserId)
    let legacy = try TokenAccount(serverURL: URL(string: serverBaseURL)!, userID: serverUserId)
    #expect(try tokenStore.load(for: account) == nil)
    #expect(try tokenStore.load(for: legacy) == nil)
    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == nil)
  }

  @Test func malformedStoredServerFailureDoesNotMasqueradeAsCompletedLocalRemoval() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "logout-uuid",
        serverBaseURL: "not a server URL",
        serverUserId: serverUserId,
        serverVersion: "2.35.1"
      )
      try record.save(db)
    }
    let service = makeAccountLifecycleService(
      transport: ScriptedAccountTransport(), database: database, tokenStore: tokenStore)

    await #expect(throws: AccountLifecycleError.malformedURL) {
      try await service.logout()
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } != nil)
  }

  @Test func logoutWithNoAccountRowIsANoOp() async throws {
    let database = try AppDatabase.inMemory()
    let service = makeAccountLifecycleService(
      transport: ScriptedAccountTransport(),
      database: database,
      tokenStore: InMemoryTokenStore()
    )

    try await service.logout()
  }
}
