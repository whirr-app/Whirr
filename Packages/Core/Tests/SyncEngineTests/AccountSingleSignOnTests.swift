import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Single sign-on through `AccountLifecycleService`. The two server legs are
/// scripted on the same transport the other lifecycle suites use; the browser in between is the
/// test building the callback URL the server's mobile redirect would send.
@Suite struct AccountSingleSignOnTests {

  private let validatedServer = ValidatedServer(
    serverURL: URL(string: "https://books.example.test")!,
    serverVersion: "2.37.2",
    isPlainHTTP: false,
    authMethods: [.local, .openID]
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

  private func stubBegin(_ transport: ScriptedAccountTransport) async {
    await transport.stub(
      path: "/auth/openid",
      response: HTTPResponse(
        statusCode: 302,
        headers: ["Location": "https://idp.example.test/authorize?client_id=abs"],
        body: Data(),
        cookies: [HTTPResponseCookie(name: "connect.sid", value: "session-1")]))
  }

  private func callback(for attempt: SingleSignOnAttempt, code: String = "code-1") throws -> URL {
    let state = try #require(attempt.oidcAttempt).state
    return try #require(URL(string: "whirr://oauth?code=\(code)&state=\(state)"))
  }

  private func account(in database: AppDatabase) throws -> AccountRecord? {
    try database.read { db in try AccountRecord.fetchOne(db) }
  }

  private func signIn(
    _ service: AccountLifecycleService, transport: ScriptedAccountTransport, userId: String
  ) async throws {
    await stubBegin(transport)
    await transport.stub(
      path: "/auth/openid/callback",
      response: makeLoginResponse(userId: userId, accessToken: "sso-access", refreshToken: "sso-refresh"))
    let attempt = try await service.beginSingleSignOn(server: validatedServer)
    try await service.login(
      server: validatedServer, singleSignOn: attempt, callbackURL: try callback(for: attempt))
  }

  @Test("a single sign-on creates the account, stores the pair and records the method")
  func singleSignOnCreatesAnOpenIDAccount() async throws {
    let transport = ScriptedAccountTransport()
    let (service, database, tokenStore) = try makeFixtures(transport: transport)

    try await signIn(service, transport: transport, userId: "user-1")

    let account = try #require(try account(in: database))
    #expect(account.serverUserId == "user-1")
    #expect(account.clientUUID == "generated-uuid")
    #expect(account.signsInWithOpenID)
    let tokens = try #require(try tokenStore.load(for: try account.credentialTokenAccount))
    #expect(tokens.accessToken == "sso-access")
    #expect(tokens.refreshToken == "sso-refresh")
    #expect(service.isAuthenticated)
    #expect(service.authenticationMode == .openID)

    let callbackRequest = try #require(await transport.requests.last)
    #expect(callbackRequest.url.path == "/auth/openid/callback")
    #expect(callbackRequest.headers["Cookie"] == "connect.sid=session-1")
  }

  @Test("a user on a mixed server who changes method has the change recorded")
  func changingMethodUpdatesTheFlag() async throws {
    let transport = ScriptedAccountTransport()
    let (service, database, _) = try makeFixtures(transport: transport)

    try await signIn(service, transport: transport, userId: "user-1")
    #expect(try account(in: database)?.signsInWithOpenID == true)

    await transport.stub(path: "/login", response: makeLoginResponse(userId: "user-1"))
    try await service.login(server: validatedServer, username: "rhys", password: "hunter2")
    #expect(try account(in: database)?.signsInWithOpenID == false)
    #expect(service.authenticationMode == .password)

    try await signIn(service, transport: transport, userId: "user-1")
    let account = try #require(try account(in: database))
    #expect(account.signsInWithOpenID)
    #expect(account.clientUUID == "generated-uuid")
    #expect(service.authenticationMode == .openID)
  }

  @Test("a cancelled browser session leaves no row, no pair and an open gate")
  func cancelLeavesNothingBehind() async throws {
    let transport = ScriptedAccountTransport()
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, database, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)
    await stubBegin(transport)

    let attempt = try await service.beginSingleSignOn(server: validatedServer)
    // Admission is not held across the browser: another sign-in could start right now.
    #expect(await gate.retryAfter() == nil)
    attempt.abandon()

    await #expect(throws: AccountLifecycleError.singleSignOnFailed(.callbackRejected)) {
      try await service.login(
        server: validatedServer, singleSignOn: attempt, callbackURL: try callback(for: attempt))
    }
    #expect(try account(in: database) == nil)
    #expect(service.isAuthenticated == false)
    #expect(await transport.requests.map(\.url.path) == ["/auth/openid"])
    #expect(await gate.admit() == nil)
  }

  @Test("an attempt is single use even when its first completion fails before the exchange")
  func attemptIsSingleUseAcrossEarlyFailures() async throws {
    let transport = ScriptedAccountTransport()
    let (service, _, _) = try makeFixtures(transport: transport)
    await stubBegin(transport)
    let attempt = try await service.beginSingleSignOn(server: validatedServer)
    let malformed = ValidatedServer(
      serverURL: URL(string: "ftp://books.example.test")!, serverVersion: "2.37.2", isPlainHTTP: false)

    await #expect(throws: AccountLifecycleError.malformedURL) {
      try await service.login(server: malformed, singleSignOn: attempt, callbackURL: try callback(for: attempt))
    }
    await #expect(throws: AccountLifecycleError.singleSignOnFailed(.callbackRejected)) {
      try await service.login(
        server: validatedServer, singleSignOn: attempt, callbackURL: try callback(for: attempt))
    }
  }

  @Test("a stand-in attempt from a fake can never complete")
  func standInAttemptIsRefused() async throws {
    let transport = ScriptedAccountTransport()
    let (service, _, _) = try makeFixtures(transport: transport)
    let standIn = SingleSignOnAttempt(authorizationURL: URL(string: "https://idp.example.test")!)

    await #expect(throws: AccountLifecycleError.singleSignOnFailed(.callbackRejected)) {
      try await service.login(
        server: validatedServer, singleSignOn: standIn,
        callbackURL: URL(string: "whirr://oauth?code=c&state=s")!)
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test("each server answer maps to its own failure, and only a refusal arms pacing")
  func failuresMapAndPaceDistinctly() async throws {
    struct Case {
      let name: String
      let begin: HTTPResponse?
      let callback: HTTPResponse?
      let expected: SingleSignOnFailure
      let armsGate: Bool
    }
    let cases = [
      Case(
        name: "redirect not allowed",
        begin: HTTPResponse(statusCode: 400, headers: [:], body: Data("Invalid redirect_uri".utf8)),
        callback: nil, expected: .redirectURINotAllowed, armsGate: false),
      Case(
        name: "unavailable",
        begin: HTTPResponse(statusCode: 500, headers: [:], body: Data()),
        callback: nil, expected: .unavailable, armsGate: false),
      Case(
        name: "expired",
        begin: nil,
        callback: HTTPResponse(statusCode: 400, headers: [:], body: Data("No session".utf8)),
        expected: .attemptExpired, armsGate: false),
      Case(
        name: "refused",
        begin: nil,
        callback: HTTPResponse(statusCode: 302, headers: ["Location": "/login?error=x"], body: Data()),
        expected: .refused, armsGate: true),
    ]
    for testCase in cases {
      let transport = ScriptedAccountTransport()
      let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
      let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
      let (service, database, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)

      let failure: Error?
      if let begin = testCase.begin {
        await transport.stub(path: "/auth/openid", response: begin)
        failure = await #expect(throws: AccountLifecycleError.self) {
          _ = try await service.beginSingleSignOn(server: validatedServer)
        }
      } else {
        await stubBegin(transport)
        await transport.stub(path: "/auth/openid/callback", response: try #require(testCase.callback))
        let attempt = try await service.beginSingleSignOn(server: validatedServer)
        failure = await #expect(throws: AccountLifecycleError.self) {
          try await service.login(
            server: validatedServer, singleSignOn: attempt, callbackURL: try callback(for: attempt))
        }
      }
      #expect(
        failure as? AccountLifecycleError == .singleSignOnFailed(testCase.expected), "\(testCase.name)")
      #expect((await gate.retryAfter() != nil) == testCase.armsGate, "\(testCase.name)")
      #expect(try account(in: database) == nil, "\(testCase.name)")
    }
  }

  @Test("a plain-HTTP server is refused before any request, without arming pacing")
  func plainHTTPServerIsRefused() async throws {
    let transport = ScriptedAccountTransport()
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let (service, _, _) = try makeFixtures(transport: transport, loginBackoffGate: gate)
    await stubBegin(transport)
    let httpServer = ValidatedServer(
      serverURL: URL(string: "http://books.example.test")!, serverVersion: "2.37.2",
      isPlainHTTP: true, authMethods: [.openID])

    await #expect(throws: AccountLifecycleError.singleSignOnFailed(.requiresHTTPS)) {
      _ = try await service.beginSingleSignOn(server: httpServer)
    }
    #expect(httpServer.offersSingleSignOn == false)
    #expect(await transport.requests.isEmpty)
    #expect(await gate.retryAfter() == nil)
  }

  @Test("an identity provider refusal never reaches the server's callback")
  func undefinedCodeIsRefusedLocally() async throws {
    let transport = ScriptedAccountTransport()
    let (service, _, _) = try makeFixtures(transport: transport)
    await stubBegin(transport)
    let attempt = try await service.beginSingleSignOn(server: validatedServer)

    await #expect(throws: AccountLifecycleError.singleSignOnFailed(.refused)) {
      try await service.login(
        server: validatedServer, singleSignOn: attempt,
        callbackURL: try callback(for: attempt, code: "undefined"))
    }
    #expect(await transport.requests.map(\.url.path) == ["/auth/openid"])
  }

  // MARK: - Re-authentication

  private func seedOpenIDAccount(database: AppDatabase, tokenStore: any TokenStoring) throws -> TokenAccount {
    let saved = try database.write { db in
      var record = AccountRecord(
        clientUUID: "existing-uuid", serverBaseURL: "https://books.example.test",
        serverUserId: "user-1", serverVersion: "2.37.2", signsInWithOpenID: true)
      try record.save(db)
      return record
    }
    let tokenAccount = try saved.credentialTokenAccount
    try tokenStore.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: tokenAccount)
    return tokenAccount
  }

  @Test("single sign-on recovery targets the stored server and replaces only the pair")
  func reauthenticationReplacesThePair() async throws {
    let transport = ScriptedAccountTransport()
    let (service, database, tokenStore) = try makeFixtures(transport: transport)
    let tokenAccount = try seedOpenIDAccount(database: database, tokenStore: tokenStore)
    let before = try account(in: database)
    #expect(service.authenticationMode == .openID)
    await stubBegin(transport)
    await transport.stub(
      path: "/auth/openid/callback",
      response: makeLoginResponse(userId: "user-1", accessToken: "new-access", refreshToken: "new-refresh"))

    let attempt = try await service.beginSingleSignOnReauthentication()
    try await service.reauthenticate(singleSignOn: attempt, callbackURL: try callback(for: attempt))

    #expect(try tokenStore.load(for: tokenAccount)?.accessToken == "new-access")
    #expect(try account(in: database) == before)
    #expect(await transport.requests.map { $0.url.host() } == ["books.example.test", "books.example.test"])
  }

  @Test("single sign-on recovery as a different user changes nothing")
  func reauthenticationRefusesADifferentUser() async throws {
    let transport = ScriptedAccountTransport()
    let (service, database, tokenStore) = try makeFixtures(transport: transport)
    let tokenAccount = try seedOpenIDAccount(database: database, tokenStore: tokenStore)
    let before = try account(in: database)
    await stubBegin(transport)
    await transport.stub(
      path: "/auth/openid/callback",
      response: makeLoginResponse(userId: "user-2", accessToken: "other", refreshToken: "other-refresh"))

    let attempt = try await service.beginSingleSignOnReauthentication()
    await #expect(throws: AccountLifecycleError.accountMismatch) {
      try await service.reauthenticate(singleSignOn: attempt, callbackURL: try callback(for: attempt))
    }
    #expect(try tokenStore.load(for: tokenAccount)?.accessToken == "old-access")
    #expect(try account(in: database) == before)
    // The IdP sign-in left the other user a live ABS session; it is revoked, not orphaned.
    let revocation = try #require(await transport.requests.last)
    #expect(revocation.routeTemplate == "/logout")
    #expect(revocation.headers["x-refresh-token"] == "other-refresh")
  }
}
