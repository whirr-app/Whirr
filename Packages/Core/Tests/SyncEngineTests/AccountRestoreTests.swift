import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Relaunch path: with tokens already in the store and an account row already present, a
/// fresh construction of the production `AccountLifecycle` (no method call needed) reports
/// `isAuthenticated == true` and never touches the persisted `clientUUID`.
@Suite struct AccountRestoreTests {

  private func seedAccount(
    in database: AppDatabase,
    tokenStore: any TokenStoring,
    clientUUID: String = "restored-uuid",
    serverBaseURL: String = "https://books.example.test",
    serverUserId: String = "user-1"
  ) async throws {
    let record = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: serverBaseURL,
        serverUserId: serverUserId,
        serverVersion: "2.35.1"
      )
      try record.save(db)
      return record
    }
    let tokenAccount = try record.credentialTokenAccount
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: tokenAccount)
  }

  @Test func freshConstructionWithStoredTokensAndAccountRowIsAuthenticated() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    try await seedAccount(in: database, tokenStore: tokenStore)

    let restored = makeAccountLifecycleService(
      transport: ScriptedAccountTransport(),
      database: database,
      tokenStore: tokenStore
    )

    #expect(restored.isAuthenticated == true)
  }

  @Test func freshConstructionPreservesTheStoredClientUUID() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    try await seedAccount(in: database, tokenStore: tokenStore, clientUUID: "must-not-change")

    _ = makeAccountLifecycleService(
      transport: ScriptedAccountTransport(),
      database: database,
      tokenStore: tokenStore
    )

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.clientUUID == "must-not-change")
  }

  @Test func accountRowWithoutStoredTokensIsNotAuthenticated() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "some-uuid",
        serverBaseURL: "https://books.example.test",
        serverUserId: "user-1",
        serverVersion: "2.35.1"
      )
      try record.save(db)
    }

    let service = makeAccountLifecycleService(
      transport: ScriptedAccountTransport(),
      database: database,
      tokenStore: InMemoryTokenStore()
    )

    #expect(service.isAuthenticated == false)
  }

  @Test func storedTokensWithoutAnAccountRowAreNotAuthenticated() throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let tokenAccount = try TokenAccount(
      serverURL: URL(string: "https://books.example.test")!, userID: "user-1")
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: tokenAccount)

    let service = makeAccountLifecycleService(
      transport: ScriptedAccountTransport(),
      database: database,
      tokenStore: tokenStore
    )

    #expect(service.isAuthenticated == false)
  }

  @Test func noAccountAtAllIsNotAuthenticated() throws {
    let service = makeAccountLifecycleService(
      transport: ScriptedAccountTransport(),
      database: try AppDatabase.inMemory(),
      tokenStore: InMemoryTokenStore()
    )

    #expect(service.isAuthenticated == false)
  }

  @Test("a tokenless row with the same identity is recovered without rebinding it")
  func tokenlessSameIdentityLoginPreservesTheRowAndSavesTokens() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "must-survive",
        serverBaseURL: "https://books.example.test",
        serverUserId: "user-1",
        serverVersion: "2.35.1"
      )
      try record.save(db)
    }
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let service = makeAccountLifecycleService(
      transport: transport, database: database, tokenStore: tokenStore)

    try await service.login(
      server: ValidatedServer(
        serverURL: URL(string: "HTTPS://BOOKS.EXAMPLE.TEST:443")!,
        serverVersion: "2.36.0",
        isPlainHTTP: false),
      username: "rhys",
      password: "hunter2")

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.clientUUID == "must-survive")
    #expect(account.serverUserId == "user-1")
    let tokenAccount = try account.credentialTokenAccount
    #expect(try tokenStore.load(for: tokenAccount)?.accessToken == "access-token")
  }

  @Test("a tokenless row with the same identity is recovered through API-token login")
  func tokenlessSameIdentityAPITokenLoginPreservesTheRowAndSavesTokens() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "must-survive",
        serverBaseURL: "https://books.example.test",
        serverUserId: "user_fixture",
        serverVersion: "2.35.1"
      )
      try record.save(db)
    }
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/api/me",
      response: HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "me-profile-response")))
    await transport.stub(
      path: "/api/libraries",
      response: HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "libraries-response")))
    let service = makeAccountLifecycleService(
      transport: transport, database: database, tokenStore: tokenStore)

    try await service.login(
      server: ValidatedServer(
        serverURL: URL(string: "https://books.example.test")!,
        serverVersion: "2.36.0",
        isPlainHTTP: false),
      apiToken: "api-token-canary")

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.clientUUID == "must-survive")
    let tokenAccount = try account.credentialTokenAccount
    #expect(try tokenStore.load(for: tokenAccount)?.accessToken == "api-token-canary")
  }

  @Test("a tokenless row rejects a login from a different server origin without mutation")
  func tokenlessDifferentServerLoginIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let original = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "must-survive",
        serverBaseURL: "https://old.example.test",
        serverUserId: "user-1",
        serverVersion: "2.35.1"
      ))
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-2"))
    let headerStore = InMemoryCustomHeaderStore()
    let oldHeaders = try CustomHeaders(["X-Proxy-Token": "old"])
    try headerStore.save(oldHeaders, for: URL(string: "https://books.example.test")!)
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      customHeaderStore: headerStore
    )

    await #expect(throws: AccountLifecycleError.deviceBoundToDifferentAccount) {
      try await service.login(
        server: ValidatedServer(
          serverURL: URL(string: "https://books.example.test")!,
          serverVersion: "2.36.0",
          isPlainHTTP: false,
          customHeaders: try CustomHeaders(["X-Proxy-Token": "new"])),
        username: "rhys",
        password: "hunter2")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == original)
    #expect(try headerStore.load(for: URL(string: "https://books.example.test")!) == oldHeaders)
    let returnedAccount = try TokenAccount(
      serverURL: URL(string: "https://books.example.test")!, userID: "user-2")
    #expect(try tokenStore.load(for: returnedAccount) == nil)
  }

  @Test("a tokenless row rejects a login for a different user on the same server")
  func tokenlessDifferentUserLoginIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let original = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "must-survive",
        serverBaseURL: "https://books.example.test",
        serverUserId: "user-1",
        serverVersion: "2.35.1"
      ))
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-2"))
    let service = makeAccountLifecycleService(
      transport: transport, database: database, tokenStore: tokenStore)

    await #expect(throws: AccountLifecycleError.deviceBoundToDifferentAccount) {
      try await service.login(
        server: ValidatedServer(
          serverURL: URL(string: "https://books.example.test")!,
          serverVersion: "2.36.0",
          isPlainHTTP: false),
        username: "rhys",
        password: "hunter2")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == original)
    let returnedAccount = try TokenAccount(
      serverURL: URL(string: "https://books.example.test")!, userID: "user-2")
    #expect(try tokenStore.load(for: returnedAccount) == nil)
  }
}
