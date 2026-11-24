import Foundation
import GRDB
import Persistence
import Security
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Login: `ABSClient.login` persists tokens (ABSApi's job); this layer creates/updates the single
/// account row (normalized identity, server user id, server version) and the default library id,
/// generating the client UUID once and preserving it on later updates.
@Suite struct AccountLoginTests {

  private let validatedServer = ValidatedServer(
    serverURL: URL(string: "https://books.example.test")!,
    serverVersion: "2.36.0",
    isPlainHTTP: false,
    customHeaders: try! CustomHeaders(["X-Proxy-Token": "proxy-secret"])
  )

  private func makeFixtures(
    transport: ScriptedAccountTransport,
    loginBackoffGate: LoginBackoffGate = LoginBackoffGate()
  ) throws -> (
    service: AccountLifecycleService, database: AppDatabase, tokenStore: any TokenStoring
  ) {
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      clientUUIDGenerator: { "generated-uuid" },
      loginBackoffGate: loginBackoffGate
    )
    return (service, database, tokenStore)
  }

  @Test func firstLoginCreatesTheAccountRowAndGeneratesTheClientUUID() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1", defaultLibraryId: "lib-42"))
    let (service, database, tokenStore) = try makeFixtures(transport: transport)

    try await service.login(server: validatedServer, username: "rhys", password: "hunter2")

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.clientUUID == "generated-uuid")
    #expect(account.serverUserId == "user-1")
    #expect(account.serverVersion == "2.36.0")
    #expect(account.defaultLibraryId == "lib-42")
    #expect(account.librarySelectionMode == .pending)
    #expect(service.isAuthenticated == true)

    let tokenAccount = try account.credentialTokenAccount
    #expect(try tokenStore.load(for: tokenAccount)?.accessToken == "access-token")
    let legacyAccount = try TokenAccount(serverURL: validatedServer.serverURL, userID: "user-1")
    #expect(try tokenStore.load(for: legacyAccount) == nil)
    let endpoints = try AccountEndpointDAO(database: database).fetchAll(accountId: try #require(account.id))
    #expect(endpoints.map(\.normalizedURL) == [account.serverBaseURL])
    #expect(endpoints.map(\.isPreferred) == [true])
  }

  @Test("API-token login validates /api/me, selects the fallback library, and preserves account identity")
  func apiTokenLoginCreatesTheSameAccountShape() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/api/me",
      response: HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "me-profile-response"))
    )
    await transport.stub(
      path: "/api/libraries",
      response: HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "libraries-response"))
    )
    let (service, database, tokenStore) = try makeFixtures(transport: transport)

    try await service.login(server: validatedServer, apiToken: "api-token-canary")

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.clientUUID == "generated-uuid")
    #expect(account.serverUserId == "user_fixture")
    #expect(account.defaultLibraryId == "library_book_fixture")
    #expect(service.isAuthenticated == true)
    #expect(await transport.requests.map(\.url.path) == ["/api/me", "/api/libraries"])
    #expect(await transport.requests.allSatisfy { $0.headers["Authorization"] == "Bearer api-token-canary" })

    let tokenAccount = try account.credentialTokenAccount
    #expect(try tokenStore.load(for: tokenAccount)?.refreshToken == nil)
    #expect(
      try tokenStore.load(for: TokenAccount(serverURL: validatedServer.serverURL, userID: account.serverUserId)) == nil)
    let endpoints = try AccountEndpointDAO(database: database).fetchAll(accountId: try #require(account.id))
    #expect(endpoints.count == 1)
    #expect(endpoints[0].normalizedURL == account.serverBaseURL)
    #expect(service.authenticationMode == .apiToken)
  }

  @Test("API-token 401s use invalid-credentials classification and arm the shared backoff gate")
  func apiTokenUnauthorizedUsesThePasswordLoginClassification() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/api/me", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, _, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.login(server: validatedServer, apiToken: "wrong-api-token")
    }

    await #expect(throws: AccountLifecycleError.loginRateLimited(retryAfter: 1)) {
      try await service.login(server: validatedServer, apiToken: "another-api-token")
    }
    #expect(await transport.requests.count == 1)
  }

  @Test("rebuilds the login client with validated headers and persists them for the server")
  func loginCarriesAndStoresCustomHeaders() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let customHeaderStore = InMemoryCustomHeaderStore()
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore)

    try await service.login(server: validatedServer, username: "rhys", password: "hunter2")

    #expect(await transport.requests.first?.headers["X-Proxy-Token"] == "proxy-secret")
    #expect(try customHeaderStore.load(for: validatedServer.serverURL) == validatedServer.customHeaders)
  }

  @Test("clears artwork only when the stored header fingerprint changes")
  func invalidatesArtworkOnHeaderChange() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let customHeaderStore = InMemoryCustomHeaderStore()
    let cacheProbe = CacheClearProbe()
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      clearCachedArtwork: { await cacheProbe.record() })
    let first = ValidatedServer(
      serverURL: validatedServer.serverURL,
      serverVersion: validatedServer.serverVersion,
      isPlainHTTP: false,
      customHeaders: try CustomHeaders(["X-Proxy-Token": "one"]))
    let same = first
    let changed = ValidatedServer(
      serverURL: validatedServer.serverURL,
      serverVersion: validatedServer.serverVersion,
      isPlainHTTP: false,
      customHeaders: try CustomHeaders(["X-Proxy-Token": "two"]))

    try await service.login(server: first, username: "rhys", password: "one")
    try await service.login(server: same, username: "rhys", password: "two")
    try await service.login(server: changed, username: "rhys", password: "three")

    #expect(await cacheProbe.count == 2)
  }

  @Test("a header persistence failure rolls back a first login completely")
  func headerPersistenceFailureRollsBackFirstLogin() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let headerStore = FailingSaveHeaderStore()
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      customHeaderStore: headerStore
    )

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == nil)
    let account = try TokenAccount(serverURL: validatedServer.serverURL, userID: "user-1")
    #expect(try tokenStore.load(for: account) == nil)
    #expect(try headerStore.load(for: validatedServer.serverURL) == nil)
  }

  @Test("a header persistence failure leaves an existing login state untouched")
  func headerPersistenceFailureRollsBackRelogin() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let oldHeaders = try CustomHeaders(["X-Proxy-Token": "old"])
    let headerStore = FailingSaveHeaderStore(headers: oldHeaders)
    let oldAccount = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "original-uuid",
        serverBaseURL: validatedServer.serverURL.absoluteString,
        serverUserId: "user-1",
        serverVersion: "2.35.1"
      ))
    let oldTokenAccount = try oldAccount.credentialTokenAccount
    try tokenStore.save(
      TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: oldTokenAccount)
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      customHeaderStore: headerStore
    )

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == oldAccount)
    #expect(try tokenStore.load(for: oldTokenAccount)?.accessToken == "old-access")
    #expect(try headerStore.load(for: validatedServer.serverURL) == oldHeaders)
  }

  @Test("an account persistence failure rolls back a first login completely")
  func accountPersistenceFailureRollsBackFirstLogin() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let headerStore = InMemoryCustomHeaderStore()
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      customHeaderStore: headerStore,
      accountRecordSaver: { _ in throw FailingAccountSaveError.saveFailed }
    )

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == nil)
    let account = try TokenAccount(serverURL: validatedServer.serverURL, userID: "user-1")
    #expect(try tokenStore.load(for: account) == nil)
    #expect(try headerStore.load(for: validatedServer.serverURL) == nil)
  }

  @Test("an account persistence failure leaves an existing login state untouched")
  func accountPersistenceFailureRollsBackRelogin() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1", defaultLibraryId: "new-lib"))
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let headerStore = InMemoryCustomHeaderStore()
    let oldHeaders = try CustomHeaders(["X-Proxy-Token": "old"])
    try headerStore.save(oldHeaders, for: validatedServer.serverURL)
    let oldAccount = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "original-uuid",
        serverBaseURL: validatedServer.serverURL.absoluteString,
        serverUserId: "user-1",
        serverVersion: "2.35.1",
        defaultLibraryId: "old-lib"
      ))
    let oldTokenAccount = try oldAccount.credentialTokenAccount
    try tokenStore.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: oldTokenAccount)
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      customHeaderStore: headerStore,
      accountRecordSaver: { _ in throw FailingAccountSaveError.saveFailed }
    )

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == oldAccount)
    #expect(try tokenStore.load(for: oldTokenAccount)?.accessToken == "old-access")
    #expect(try headerStore.load(for: validatedServer.serverURL) == oldHeaders)
  }

  @Test func loginUpdatingAnExistingAccountPreservesItsClientUUID() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1", defaultLibraryId: "lib-99"))
    let (service, database, _) = try makeFixtures(transport: transport)

    try await database.writeAsync { db in
      var existing = AccountRecord(
        clientUUID: "original-uuid",
        serverBaseURL: "https://books.example.test",
        serverUserId: "user-1",
        serverVersion: "2.35.1",
        librarySelectionMode: .selected
      )
      try existing.save(db)
    }

    try await service.login(server: validatedServer, username: "rhys", password: "hunter2")

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.clientUUID == "original-uuid")
    #expect(account.serverVersion == "2.36.0")
    #expect(account.librarySelectionMode == .selected)
    #expect(try database.read { db in try AccountRecord.fetchCount(db) } == 1)
  }

  @Test("a second login through the same URL does not add an endpoint")
  func repeatedLoginDoesNotDuplicateEndpoint() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let (service, database, _) = try makeFixtures(transport: transport)

    try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    try await service.login(server: validatedServer, username: "rhys", password: "hunter2")

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(try AccountEndpointDAO(database: database).fetchAll(accountId: try #require(account.id)).count == 1)
  }

  @Test("a URL difference alone does not trigger device binding")
  func differentURLWithSameUserIsAccepted() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let service = makeAccountLifecycleService(
      transport: transport, database: database, tokenStore: tokenStore,
      clientUUIDGenerator: { "existing-uuid" })
    let firstServer = ValidatedServer(
      serverURL: URL(string: "https://books.example.test")!, serverVersion: "2.36.0",
      isPlainHTTP: false, customHeaders: .none)
    try await service.login(server: firstServer, username: "rhys", password: "hunter2")

    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let secondServer = ValidatedServer(
      serverURL: URL(string: "https://books-alt.example.test")!, serverVersion: "2.36.0",
      isPlainHTTP: false, customHeaders: .none)
    try await service.login(server: secondServer, username: "rhys", password: "hunter2")

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.serverUserId == "user-1")
    #expect(try AccountEndpointDAO(database: database).fetchAll(accountId: try #require(account.id)).count == 2)
  }

  @Test func badCredentialsClassifyDistinctlyFromTransportFailure() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    let (service, database, tokenStore) = try makeFixtures(transport: transport)

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.login(server: validatedServer, username: "rhys", password: "wrong")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == nil)
    #expect(service.isAuthenticated == false)
    _ = tokenStore
  }

  @Test("a failed login blocks the next attempt before it reaches the transport")
  func failedLoginBlocksTheNextAttemptBeforeTransport() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", error: URLError(.notConnectedToInternet))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, _, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)

    await #expect(throws: AccountLifecycleError.unreachable) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }

    do {
      try await service.login(server: validatedServer, username: "rhys", password: "correct")
      Issue.record("expected the second login attempt to be rate limited")
    } catch let error as AccountLifecycleError {
      guard case .loginRateLimited(let retryAfter) = error else {
        Issue.record("expected loginRateLimited, got \(error)")
        return
      }
      #expect(retryAfter == 1)
    }

    #expect(await transport.requests.count == 1)
    _ = clock
  }

  @Test("a login is admitted once the backoff delay elapses")
  func loginIsAdmittedOnceBackoffDelayElapses() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, _, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.login(server: validatedServer, username: "rhys", password: "wrong")
    }

    clock.advance(by: 1)
    try await service.login(server: validatedServer, username: "rhys", password: "correct")

    #expect(await transport.requests.count == 2)
  }

  @Test("a successful login resets the next failure to the first delay")
  func successfulLoginResetsTheNextFailureToTheFirstDelay() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    await transport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, _, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.login(server: validatedServer, username: "rhys", password: "wrong")
    }
    clock.advance(by: 1)
    try await service.login(server: validatedServer, username: "rhys", password: "correct")

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.login(server: validatedServer, username: "rhys", password: "wrong-again")
    }

    let retryAfter = await gate.retryAfter()
    #expect(retryAfter == 1)
    #expect(await transport.requests.count == 3)
  }

  @Test("the first failure delay never exceeds one second")
  func firstFailureDelayNeverExceedsOneSecond() async {
    let gate = LoginBackoffGate(
      now: { Date(timeIntervalSince1970: 0) },
      randomUnit: { 1 }
    )

    await gate.recordFailure()

    let retryAfter = await gate.retryAfter()
    #expect(retryAfter != nil)
    #expect(retryAfter ?? .infinity <= 1)
  }

  @Test("an invalid-credentials failure arms the login backoff")
  func invalidCredentialsFailureArmsTheLoginBackoff() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, _, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.login(server: validatedServer, username: "rhys", password: "wrong")
    }

    do {
      try await service.login(server: validatedServer, username: "rhys", password: "correct")
      Issue.record("expected the invalid-credentials failure to arm the gate")
    } catch let error as AccountLifecycleError {
      guard case .loginRateLimited = error else {
        Issue.record("expected loginRateLimited, got \(error)")
        return
      }
    }

    #expect(await transport.requests.count == 1)
    _ = clock
  }

  @Test func transportFailureDuringLoginClassifiesAsUnreachable() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", error: URLError(.notConnectedToInternet))
    let (service, _, _) = try makeFixtures(transport: transport)

    await #expect(throws: AccountLifecycleError.unreachable) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }
  }

  @Test func passwordNeverLandsInAnyStoredPropertyAfterLogin() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let (service, _, _) = try makeFixtures(transport: transport)
    let canary = "hunter2-canary-password"

    try await service.login(server: validatedServer, username: "rhys", password: canary)

    var dumped = ""
    dump(service, to: &dumped)
    #expect(dumped.contains(canary) == false)
  }

  // MARK: - Post-authentication persistence failures

  /// The remaining two `finishLogin` throw sites the rollback tests above don't reach: the
  /// header-store read that captures the rollback snapshot, and the Keychain token write inside
  /// `commitLogin`. All four classify as `.localPersistenceFailed` so the setup flow can say the
  /// sign-in worked but this device couldn't save it, rather than falling through to the
  /// catch-all's generic copy.
  @Test("a header-store read failure after authentication classifies as a local persistence failure")
  func headerLoadFailureAfterAuthenticationClassifies() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    let tokenStore = InMemoryTokenStore()
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: tokenStore,
      customHeaderStore: FailingLoadHeaderStore()
    )

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == nil)
    let account = try TokenAccount(serverURL: validatedServer.serverURL, userID: "user-1")
    #expect(try tokenStore.load(for: account) == nil)
  }

  @Test("a token-commit failure after authentication classifies as a local persistence failure")
  func tokenCommitFailureAfterAuthenticationClassifies() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let database = try AppDatabase.inMemory()
    let headerStore = InMemoryCustomHeaderStore()
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: FakeTokenStoring(saveFailure: FakeTokenStoring.Failure()),
      customHeaderStore: headerStore
    )

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }

    #expect(try database.read { db in try AccountRecord.fetchOne(db) } == nil)
    #expect(try headerStore.load(for: validatedServer.serverURL) == nil)
  }

  /// -34018 is `errSecMissingEntitlement`: the build is missing its Keychain access group. The
  /// device is unlocked, the disk is empty, and the user cannot fix it, so it must not land on
  /// `.localPersistenceFailed`, whose copy tells them to unlock the device and free up space.
  @Test("a missing-entitlement token write classifies as an unavailable keychain, not a disk problem")
  func missingEntitlementTokenWriteClassifiesAsKeychainUnavailable() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let service = makeAccountLifecycleService(
      transport: transport,
      database: try AppDatabase.inMemory(),
      tokenStore: FakeTokenStoring(
        saveFailure: KeychainStoreError.keychainFailure(status: errSecMissingEntitlement))
    )

    await #expect(throws: AccountLifecycleError.keychainUnavailable) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }
  }

  @Test("a missing-entitlement header write classifies as an unavailable keychain")
  func missingEntitlementHeaderWriteClassifiesAsKeychainUnavailable() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let service = makeAccountLifecycleService(
      transport: transport,
      database: try AppDatabase.inMemory(),
      tokenStore: InMemoryTokenStore(),
      customHeaderStore: FailingSaveHeaderStore(
        error: KeychainStoreError.keychainFailure(status: errSecMissingEntitlement))
    )

    await #expect(throws: AccountLifecycleError.keychainUnavailable) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }
  }

  /// Every other Keychain status is still a genuine write failure the user may be able to clear.
  @Test("a non-entitlement keychain failure keeps the local-persistence classification")
  func otherKeychainFailuresStayLocalPersistenceFailures() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let service = makeAccountLifecycleService(
      transport: transport,
      database: try AppDatabase.inMemory(),
      tokenStore: FakeTokenStoring(
        saveFailure: KeychainStoreError.keychainFailure(status: errSecInteractionNotAllowed))
    )

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }
  }

  // MARK: - Pre-authentication local reads

  /// `existingAccountState()` reads the Keychain before any credential leaves the device. A
  /// `KeychainStoreError` is not an `AccountLifecycleError`, so rethrowing it raw would fall
  /// through `SetupFlowModel`'s catch-all to the unrecoverable "Something went wrong. Try again in
  /// a moment." The read only happens once a row exists to derive a `TokenAccount` from (re-signing
  /// in on a device that already holds an account).
  @Test("a keychain read failure before the request is sent is classified, not rethrown raw")
  func preAuthenticationKeychainReadFailureIsClassified() async throws {
    let transport = ScriptedAccountTransport()
    let database = try AppDatabase.inMemory()
    try seedAccountRow(database: database)
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: FakeTokenStoring(
        loadFailure: KeychainStoreError.keychainFailure(status: errSecInteractionNotAllowed))
    )

    await #expect(throws: AccountLifecycleError.localStateUnreadable) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test("the same read failing for a missing entitlement names the build, not the device")
  func preAuthenticationMissingEntitlementIsClassifiedAsKeychainUnavailable() async throws {
    let transport = ScriptedAccountTransport()
    let database = try AppDatabase.inMemory()
    try seedAccountRow(database: database)
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: FakeTokenStoring(
        loadFailure: KeychainStoreError.keychainFailure(status: errSecMissingEntitlement))
    )

    await #expect(throws: AccountLifecycleError.keychainUnavailable) {
      try await service.login(server: validatedServer, apiToken: "api-token-canary")
    }
    #expect(await transport.requests.isEmpty)
  }

  @discardableResult
  private func seedAccountRow(database: AppDatabase, serverUserId: String = "user-1") throws -> AccountRecord {
    try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "existing-uuid",
        serverBaseURL: validatedServer.serverURL.absoluteString,
        serverUserId: serverUserId,
        serverVersion: "2.35.1"
      ))
  }

  /// The device-binding check runs before any write, so it keeps its own case. Wrapping it in
  /// `.localPersistenceFailed` would lose the "remove the other account's data first" recovery.
  @Test("the device-binding refusal is not reclassified as a persistence failure")
  func deviceBindingRefusalKeepsItsOwnClassification() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-2"))
    let database = try AppDatabase.inMemory()
    _ = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "original-uuid",
        serverBaseURL: validatedServer.serverURL.absoluteString,
        serverUserId: "user-1",
        serverVersion: "2.35.1"
      ))
    let service = makeAccountLifecycleService(
      transport: transport,
      database: database,
      tokenStore: InMemoryTokenStore()
    )

    await #expect(throws: AccountLifecycleError.deviceBoundToDifferentAccount) {
      try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    }
  }
}

private actor CacheClearProbe {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private final class FailingSaveHeaderStore: CustomHeaderStoring, @unchecked Sendable {
  enum Error: Swift.Error, Sendable, Equatable { case saveFailed }
  private var stored: CustomHeaders?
  private let error: Swift.Error

  init(headers: CustomHeaders? = nil, error: Swift.Error = Error.saveFailed) {
    stored = headers
    self.error = error
  }

  func save(_ headers: CustomHeaders, for serverURL: URL) throws {
    throw error
  }

  func load(for serverURL: URL) throws -> CustomHeaders? { stored }
  func clear(for serverURL: URL) throws { stored = nil }
}

private final class FailingLoadHeaderStore: CustomHeaderStoring, @unchecked Sendable {
  enum Error: Swift.Error, Sendable, Equatable { case loadFailed }

  func save(_ headers: CustomHeaders, for serverURL: URL) throws {}
  func load(for serverURL: URL) throws -> CustomHeaders? { throw Error.loadFailed }
  func clear(for serverURL: URL) throws {}
}

private enum FailingAccountSaveError: Swift.Error, Sendable, Equatable {
  case saveFailed
}
