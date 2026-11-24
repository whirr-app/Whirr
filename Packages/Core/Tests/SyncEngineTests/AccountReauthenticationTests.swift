import Foundation
import GRDB
import Persistence
import Security
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The same-account recovery boundary (`AccountLifecycle.reauthenticate(username:password:)`,
/// backed by `ABSClient.reauthenticate`). Mirrors `AccountLoginTests`'s fixtures but seeds an
/// `AccountRecord` directly, as recovery is only reached from an authenticated account.
@Suite struct AccountReauthenticationTests {

  private func makeFixtures(
    transport: ScriptedAccountTransport,
    recordServer: @escaping @Sendable (ABSServerConfig) -> Void = { _ in },
    loginBackoffGate: LoginBackoffGate = LoginBackoffGate(),
    tokenStore: any TokenStoring = InMemoryTokenStore()
  ) throws -> (
    service: AccountLifecycleService, database: AppDatabase, tokenStore: any TokenStoring
  ) {
    let database = try AppDatabase.inMemory()
    let service = AccountLifecycleService(
      tokenStore: tokenStore,
      accountDAO: AccountDAO(database: database),
      accountEndpointDAO: AccountEndpointDAO(database: database),
      accountRemover: AccountRemover(database: database),
      clientFactory: { server, tokenStore in
        recordServer(server)
        return ABSClient(server: server, httpClient: transport, tokenStore: tokenStore)
      },
      loginBackoffGate: loginBackoffGate
    )
    return (service, database, tokenStore)
  }

  private func seedAccount(
    database: AppDatabase,
    serverBaseURL: String = "https://books.example.test",
    serverUserId: String = "user-1"
  ) async throws {
    try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: "existing-uuid",
        serverBaseURL: serverBaseURL,
        serverUserId: serverUserId,
        serverVersion: "2.36.0"
      )
      try record.save(db)
    }
  }

  @Test func reauthenticationTargetsStoredServerAndUser() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/login",
      response: makeLoginResponse(userId: "user-1", accessToken: "new-access", refreshToken: "new-refresh"))
    let recordedServers = Locked<[ABSServerConfig]>([])
    let (service, database, tokenStore) = try makeFixtures(transport: transport) { server in
      recordedServers.withValue { $0.append(server) }
    }
    try await seedAccount(database: database, serverBaseURL: "https://books.example.test", serverUserId: "user-1")

    // Caller supplies only username/password, never a server or expected user id.
    try await service.reauthenticate(username: "rhys", password: "hunter2")

    #expect(recordedServers.value.map(\.baseURL) == [URL(string: "https://books.example.test")!])
    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    let tokenAccount = try account.credentialTokenAccount
    #expect(try tokenStore.load(for: tokenAccount)?.accessToken == "new-access")
    #expect(try tokenStore.load(for: tokenAccount)?.refreshToken == "new-refresh")
  }

  @Test("API-token reauthentication uses the stored account and records the no-refresh mode")
  func apiTokenReauthenticationTargetsStoredAccount() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/api/me",
      response: HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "me-profile-response"))
    )
    let (service, database, tokenStore) = try makeFixtures(transport: transport)
    try await seedAccount(database: database, serverUserId: "user_fixture")

    try await service.reauthenticate(apiToken: "replacement-api-token")

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    let tokenAccount = try account.credentialTokenAccount
    #expect(try tokenStore.load(for: tokenAccount)?.accessToken == "replacement-api-token")
    #expect(try tokenStore.load(for: tokenAccount)?.refreshToken == nil)
    #expect(service.authenticationMode == .apiToken)
  }

  @Test("API-token reauthentication rejects a different user without changing the account row")
  func differentUserAPITokenRequiresExplicitAccountSwitch() async throws {
    let transport = ScriptedAccountTransport()
    let otherProfile: [String: Any] = [
      "id": "user-2",
      "username": "other-user",
      "type": "user",
      "isActive": true,
      "isLocked": false,
      "librariesAccessible": [String](),
      "permissions": [String: Any](),
    ]
    let otherProfileData = try JSONSerialization.data(withJSONObject: otherProfile)
    await transport.stub(
      path: "/api/me", response: HTTPResponse(statusCode: 200, headers: [:], body: otherProfileData))
    let (service, database, tokenStore) = try makeFixtures(transport: transport)
    try await seedAccount(database: database, serverUserId: "user-1")

    await #expect(throws: AccountLifecycleError.accountMismatch) {
      try await service.reauthenticate(apiToken: "other-api-token")
    }

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.serverUserId == "user-1")
    #expect(account.clientUUID == "existing-uuid")
    let rightAccount = try account.credentialTokenAccount
    let wrongAccount = try TokenAccount(
      credentialNamespace: account.credentialNamespace, userID: "user-2")
    #expect(try tokenStore.load(for: rightAccount) == nil)
    #expect(try tokenStore.load(for: wrongAccount) == nil)
  }

  @Test func differentReturnedUserRequiresExplicitAccountSwitch() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-2"))
    let (service, database, tokenStore) = try makeFixtures(transport: transport)
    try await seedAccount(database: database, serverUserId: "user-1")

    await #expect(throws: AccountLifecycleError.accountMismatch) {
      try await service.reauthenticate(username: "rhys", password: "hunter2")
    }

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.serverUserId == "user-1")
    let wrongTokenAccount = try TokenAccount(
      credentialNamespace: account.credentialNamespace, userID: "user-2")
    let rightTokenAccount = try account.credentialTokenAccount
    #expect(try tokenStore.load(for: wrongTokenAccount) == nil)
    #expect(try tokenStore.load(for: rightTokenAccount) == nil)
  }

  @Test func reauthenticationFailureNeverMutatesAccountRow() async throws {
    // Invalid credentials.
    let invalidCredentialsTransport = ScriptedAccountTransport()
    await invalidCredentialsTransport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    let (invalidCredentialsService, invalidCredentialsDatabase, invalidCredentialsTokenStore) =
      try makeFixtures(transport: invalidCredentialsTransport)
    try await seedAccount(database: invalidCredentialsDatabase)

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await invalidCredentialsService.reauthenticate(username: "rhys", password: "wrong")
    }
    let accountAfterInvalidCredentials = try #require(
      try invalidCredentialsDatabase.read { db in try AccountRecord.fetchOne(db) })
    #expect(accountAfterInvalidCredentials.serverUserId == "user-1")
    #expect(accountAfterInvalidCredentials.serverBaseURL == "https://books.example.test")
    let tokenAccount = try
      (try #require(
        try invalidCredentialsDatabase.read { db in try AccountRecord.fetchOne(db) }
      )).credentialTokenAccount
    #expect(try invalidCredentialsTokenStore.load(for: tokenAccount) == nil)

    // Unreachable server.
    let unreachableTransport = ScriptedAccountTransport()
    await unreachableTransport.stub(path: "/login", error: URLError(.notConnectedToInternet))
    let (unreachableService, unreachableDatabase, unreachableTokenStore) =
      try makeFixtures(transport: unreachableTransport)
    try await seedAccount(database: unreachableDatabase)

    await #expect(throws: AccountLifecycleError.unreachable) {
      try await unreachableService.reauthenticate(username: "rhys", password: "hunter2")
    }
    let accountAfterUnreachable = try #require(
      try unreachableDatabase.read { db in try AccountRecord.fetchOne(db) })
    #expect(accountAfterUnreachable.serverUserId == "user-1")
    #expect(try unreachableTokenStore.load(for: tokenAccount) == nil)
  }

  @Test("a gated reauthentication reports rate limiting without claiming invalid credentials")
  func gatedReauthenticationReportsRateLimiting() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, database, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)
    try await seedAccount(database: database)

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.reauthenticate(username: "rhys", password: "wrong")
    }

    do {
      try await service.reauthenticate(username: "rhys", password: "correct")
      Issue.record("expected the second reauthentication to be rate limited")
    } catch let error as AccountLifecycleError {
      guard case .loginRateLimited(let retryAfter) = error else {
        Issue.record("expected loginRateLimited, got \(error)")
        return
      }
      #expect(retryAfter == 1)
      #expect(error != .invalidCredentials)
    }

    #expect(await transport.requests.count == 1)
  }

  @Test("reauthentication is admitted after its backoff delay elapses")
  func reauthenticationIsAdmittedAfterBackoffDelayElapses() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, database, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)
    try await seedAccount(database: database)

    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.reauthenticate(username: "rhys", password: "wrong")
    }
    clock.advance(by: 1)

    try await service.reauthenticate(username: "rhys", password: "correct")

    #expect(await transport.requests.count == 2)
  }

  // MARK: - Post-authentication persistence failures

  /// `ABSClient.reauthenticate` writes the rotated pair to the Keychain after the server has
  /// accepted the credentials and the identity guard has passed. That write must not be classified
  /// by `classifyTransportFailure` as `.unreachable`, whose copy tells the user to check a
  /// connection that was demonstrably working.
  @Test("a Keychain write failure during password re-authentication is not reported as unreachable")
  func passwordReauthenticationKeychainFailureClassifies() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let (service, database, _) = try makeFixtures(
      transport: transport, tokenStore: FakeTokenStoring(saveFailure: FakeTokenStoring.Failure()))
    try await seedAccount(database: database)

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.reauthenticate(username: "rhys", password: "hunter2")
    }

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.serverUserId == "user-1")
    #expect(account.clientUUID == "existing-uuid")
  }

  @Test("a Keychain write failure during API-token re-authentication is not reported as unreachable")
  func apiTokenReauthenticationKeychainFailureClassifies() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/api/me",
      response: HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "me-profile-response"))
    )
    let (service, database, _) = try makeFixtures(
      transport: transport, tokenStore: FakeTokenStoring(saveFailure: FakeTokenStoring.Failure()))
    // The identity guard must pass, so the seeded row carries the fixture's user id.
    try await seedAccount(database: database, serverUserId: "user_fixture")

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.reauthenticate(apiToken: "pasted-token")
    }

    let account = try #require(try database.read { db in try AccountRecord.fetchOne(db) })
    #expect(account.serverUserId == "user_fixture")
  }

  /// -34018 is `errSecMissingEntitlement`: this build cannot reach its Keychain access group at
  /// all. "Unlock the device and free up space" is the wrong instruction, and retrying will never
  /// succeed, so the rotated-pair write has to carry the same distinction the login path does.
  @Test("a missing-entitlement rotated-pair write names the build rather than the device")
  func reauthenticationMissingEntitlementClassifiesAsKeychainUnavailable() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let (service, database, _) = try makeFixtures(
      transport: transport,
      tokenStore: FakeTokenStoring(
        saveFailure: KeychainStoreError.keychainFailure(status: errSecMissingEntitlement)))
    try await seedAccount(database: database)

    await #expect(throws: AccountLifecycleError.keychainUnavailable) {
      try await service.reauthenticate(username: "rhys", password: "hunter2")
    }
  }

  /// The recovery copy tells the user to try again. Arming the shared login backoff on a purely
  /// local failure would block that retry, and the server never misbehaved: it returned a valid
  /// login response.
  @Test("a Keychain write failure does not arm the login backoff against the server")
  func keychainFailureDoesNotArmTheLoginBackoff() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, database, _) = try makeFixtures(
      transport: transport, loginBackoffGate: gate,
      tokenStore: FakeTokenStoring(saveFailure: FakeTokenStoring.Failure()))
    try await seedAccount(database: database)

    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.reauthenticate(username: "rhys", password: "hunter2")
    }

    // No clock advance: an immediately retried attempt must still reach the transport.
    await #expect(throws: AccountLifecycleError.localPersistenceFailed) {
      try await service.reauthenticate(username: "rhys", password: "hunter2")
    }

    #expect(await transport.requests.count == 2)
  }

  /// An account mismatch means the server accepted the credentials: they were valid, just for a
  /// different user. The gate exists to avoid hammering a server that is failing or rejecting, and
  /// this server did neither, so pacing here only obstructs the retry the recovery copy invites.
  @Test("an account mismatch does not arm the login backoff against the server")
  func accountMismatchDoesNotArmTheLoginBackoff() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-other"))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-other"))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, database, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)
    try await seedAccount(database: database)

    await #expect(throws: AccountLifecycleError.accountMismatch) {
      try await service.reauthenticate(username: "rhys", password: "hunter2")
    }

    // No clock advance: an immediately retried attempt must still reach the transport.
    await #expect(throws: AccountLifecycleError.accountMismatch) {
      try await service.reauthenticate(username: "rhys", password: "hunter2")
    }

    // Each refused attempt also revokes the other user's new session; only the sign-ins count here.
    #expect(await transport.requests.filter { $0.routeTemplate == "/login" }.count == 2)
  }

  /// Not arming must not mean clearing. `recordSuccess()` would reset the policy's failure
  /// counter, erasing pacing earned by genuine wrong-password attempts, so an unjudged attempt
  /// releases its reservation instead, leaving the counter where it was.
  @Test("an unjudged attempt neither arms the backoff nor erases earlier failure history")
  func unjudgedAttemptPreservesEarlierFailureHistory() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-other"))
    await transport.stub(
      path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, database, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)
    try await seedAccount(database: database)

    // A genuine credential rejection: first delay, so the failure counter is now 1.
    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.reauthenticate(username: "rhys", password: "wrong")
    }
    #expect(await gate.retryAfter() == 1)
    clock.advance(by: 1)

    // A mismatch in between is not judged: no new window, and the counter is left alone.
    await #expect(throws: AccountLifecycleError.accountMismatch) {
      try await service.reauthenticate(username: "rhys", password: "hunter2")
    }
    #expect(await gate.retryAfter() == nil)

    // The next genuine rejection therefore escalates to the second delay, not back to the first.
    await #expect(throws: AccountLifecycleError.invalidCredentials) {
      try await service.reauthenticate(username: "rhys", password: "wrong")
    }
    #expect(await gate.retryAfter() == 2)
  }
}
