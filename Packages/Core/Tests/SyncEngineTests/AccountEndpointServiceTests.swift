import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite struct AccountEndpointServiceTests {
  private let activeURL = URL(string: "https://active.example.test")!
  private let candidateURL = URL(string: "https://candidate.example.test")!
  private let userID = "user-1"

  @Test("token proof inserts a reached, non-active endpoint without changing tokens")
  func tokenProof() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/api/me", response: profileResponse(userID: userID))
    let fixture = try makeFixture(transport: transport)
    let oldTokens = try #require(try fixture.tokenStore.load(for: fixture.tokenAccount))

    let endpoint = try await fixture.service.add(
      url: candidateURL, customHeaders: ["X-Candidate-Proxy": "candidate-secret"])

    #expect(endpoint.isPreferred == false)
    #expect(endpoint.normalizedURL == candidateURL.absoluteString)
    #expect(endpoint.lastReachedAt == fixture.now)
    #expect(try fixture.tokenStore.load(for: fixture.tokenAccount) == oldTokens)
    let requests = await transport.requests
    #expect(requests.map(\.url.host) == ["candidate.example.test", "candidate.example.test"])
    #expect(requests[0].headers["X-Candidate-Proxy"] == "candidate-secret")
    #expect(requests[1].headers["X-Candidate-Proxy"] == "candidate-secret")
    #expect(requests[1].headers["Authorization"] == "Bearer old-access")
    let account = try fixture.database.read { db in try AccountRecord.fetchOne(db) }
    #expect(account?.serverBaseURL == activeURL.absoluteString)
    #expect(account?.credentialNamespace == "account:stable-client")
  }

  @Test("an expiring access token is renewed through the live closure before the candidate sees it")
  func expiringTokenRefreshesBeforeProof() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/api/me", response: profileResponse(userID: userID))
    let refreshes = TokenAccountRecorder()
    let fixture = try makeFixture(
      transport: transport,
      storedTokens: TokenPair(
        accessToken: "old-access", refreshToken: "old-refresh",
        accessExpiry: Date(timeIntervalSince1970: 60)),
      refreshLiveTokens: { account in
        await refreshes.record(account)
        return TokenPair(accessToken: "new-access", refreshToken: "new-refresh")
      })

    _ = try await fixture.service.add(url: candidateURL, customHeaders: [:])

    #expect(await refreshes.values == [fixture.tokenAccount])
    let requests = await transport.requests
    #expect(requests.map(\.url.path) == ["/status", "/api/me"])
    #expect(requests[1].headers["Authorization"] == "Bearer new-access")
  }

  @Test("a candidate 401 is a mismatch and the candidate never receives a second token")
  func candidateUnauthorizedSendsNoSecondToken() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/api/me", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    await transport.stub(path: "/api/me", response: profileResponse(userID: userID))
    let refreshes = TokenAccountRecorder()
    let fixture = try makeFixture(
      transport: transport,
      refreshLiveTokens: { account in
        await refreshes.record(account)
        return TokenPair(accessToken: "new-access", refreshToken: "new-refresh")
      })

    await #expect(throws: AccountEndpointError.differentServerOrUser) {
      try await fixture.service.add(url: candidateURL, customHeaders: [:])
    }
    #expect(await refreshes.values.isEmpty)
    let requests = await transport.requests
    #expect(requests.map(\.url.path) == ["/status", "/api/me"])
    #expect(requests[1].headers["Authorization"] == "Bearer old-access")
    #expect(try fixture.endpointDAO.fetchAll(accountId: fixture.accountID).count == 1)
  }

  @Test("a rejected renewal before proof asks for credentials and sends the candidate nothing")
  func rejectedRenewalSendsNoToken() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    let fixture = try makeFixture(
      transport: transport,
      storedTokens: TokenPair(
        accessToken: "old-access", refreshToken: "old-refresh",
        accessExpiry: Date(timeIntervalSince1970: 0)),
      refreshLiveTokens: { _ in throw APIError.unauthorized })

    await #expect(throws: AccountEndpointError.credentialsRequired) {
      try await fixture.service.add(url: candidateURL, customHeaders: [:])
    }
    #expect(await transport.requests.map(\.url.path) == ["/status"])
  }

  @Test("a tokenless account can prove an address with password credentials")
  func passwordProofCommitsNamespaceTokens() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(
      path: "/login",
      response: makeLoginResponse(
        userId: userID, accessToken: "login-access", refreshToken: "login-refresh"))
    let fixture = try makeFixture(transport: transport, storeTokens: false)

    await #expect(throws: AccountEndpointError.credentialsRequired) {
      try await fixture.service.add(url: candidateURL, customHeaders: [:])
    }
    _ = try await fixture.service.add(
      url: candidateURL,
      customHeaders: [:],
      credentials: .password(username: "rhys", password: "hunter2"))

    #expect(
      try fixture.tokenStore.load(for: fixture.tokenAccount)
        == TokenPair(accessToken: "login-access", refreshToken: "login-refresh"))
    #expect(await transport.requests.map(\.url.path) == ["/status", "/status", "/login"])
  }

  /// API-CONVENTIONS rule 5a: the login route backs off after the first failure, on every path.
  @Test("a rejected credential proof arms login pacing, which refuses the next try unsent")
  func rejectedProofArmsPacing() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/login", response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    let clock = MutableDateSource(Date(timeIntervalSince1970: 0))
    let gate = LoginBackoffGate(now: { clock.now }, randomUnit: { 1 })
    let fixture = try makeFixture(transport: transport, storeTokens: false, loginBackoffGate: gate)
    let credentials = AccountEndpointService.EndpointProofCredentials.password(
      username: "rhys", password: "wrong")

    await #expect(throws: AccountLifecycleError.self) {
      try await fixture.service.add(url: candidateURL, customHeaders: [:], credentials: credentials)
    }
    let retry = await #expect(throws: AccountLifecycleError.self) {
      try await fixture.service.add(url: candidateURL, customHeaders: [:], credentials: credentials)
    }

    guard case .loginRateLimited = retry else {
      Issue.record("expected a rate limit, got \(String(describing: retry))")
      return
    }
    #expect(await transport.requests.map(\.url.path) == ["/status", "/login", "/status"])
  }

  @Test("credentials for a different user are discarded without logout or persistence")
  func credentialsMismatchDoesNotCommit() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(
      path: "/login", response: makeLoginResponse(userId: "other-user"))
    let fixture = try makeFixture(transport: transport, storeTokens: false)

    await #expect(throws: AccountEndpointError.differentServerOrUser) {
      try await fixture.service.add(
        url: candidateURL,
        customHeaders: [:],
        credentials: .password(username: "rhys", password: "hunter2"))
    }
    #expect(try fixture.tokenStore.load(for: fixture.tokenAccount) == nil)
    #expect(await transport.requests.map(\.url.path) == ["/status", "/login"])
  }

  @Test("candidate headers are isolated from another endpoint")
  func headerIsolation() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/api/me", response: profileResponse(userID: userID))
    let headers = InMemoryCustomHeaderStore()
    try headers.save(try CustomHeaders(["X-Existing-Proxy": "existing-secret"]), for: activeURL)
    let fixture = try makeFixture(transport: transport, headers: headers)

    let added = try await fixture.service.add(
      url: candidateURL, customHeaders: ["X-Candidate-Proxy": "candidate-secret"])
    let requests = await transport.requests
    #expect(requests.allSatisfy { $0.headers["X-Existing-Proxy"] == nil })
    #expect(requests.allSatisfy { $0.headers["X-Candidate-Proxy"] == "candidate-secret" })
    #expect(try headers.load(for: activeURL)?.headers == ["X-Existing-Proxy": "existing-secret"])

    try await fixture.service.remove(id: try #require(added.id))

    #expect(try headers.load(for: activeURL)?.headers == ["X-Existing-Proxy": "existing-secret"])
    #expect(try headers.load(for: candidateURL) == nil)
  }

  @Test("status identity and duplicate normalization reject without inserting")
  func statusAndDuplicateRejections() async throws {
    let wrongTransport = ScriptedAccountTransport()
    await wrongTransport.stub(
      path: "/status", response: makeStatusResponse(serverVersion: "2.36.0", app: "nginx"))
    let wrong = try makeFixture(transport: wrongTransport)
    await #expect(throws: AccountLifecycleError.notAudiobookshelfServer) {
      try await wrong.service.add(url: candidateURL, customHeaders: [:])
    }
    #expect(try wrong.endpointDAO.fetchAll(accountId: wrong.accountID).count == 1)

    let duplicate = try makeFixture(transport: ScriptedAccountTransport())
    await #expect(throws: AccountEndpointError.duplicateAddress) {
      try await duplicate.service.add(url: activeURL.appendingPathComponent(""), customHeaders: [:])
    }
  }

  @Test("a proxy refusal or refused redirect on status is named and inserts nothing")
  func statusRefusalsAreNamed() async throws {
    let blockedTransport = ScriptedAccountTransport()
    await blockedTransport.stub(
      path: "/status", response: HTTPResponse(statusCode: 403, headers: [:], body: Data()))
    let blocked = try makeFixture(transport: blockedTransport)
    await #expect(throws: AccountLifecycleError.blockedByProxy) {
      try await blocked.service.add(url: candidateURL, customHeaders: [:])
    }
    #expect(try blocked.endpointDAO.fetchAll(accountId: blocked.accountID).count == 1)

    let target = try #require(URL(string: "https://elsewhere.example.test/status"))
    let redirectTransport = ScriptedAccountTransport()
    await redirectTransport.stub(path: "/status", error: RefusedRedirectError(target: target))
    let redirected = try makeFixture(transport: redirectTransport)
    await #expect(throws: AccountLifecycleError.redirected(target: target)) {
      try await redirected.service.add(url: candidateURL, customHeaders: [:])
    }
    #expect(try redirected.endpointDAO.fetchAll(accountId: redirected.accountID).count == 1)
  }

  @Test("remove maps endpoint guards and clears only a successful endpoint")
  func removeGuards() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/api/me", response: profileResponse(userID: userID))
    let headers = InMemoryCustomHeaderStore()
    try headers.save(try CustomHeaders(["X-Existing-Proxy": "existing-secret"]), for: activeURL)
    let fixture = try makeFixture(transport: transport, headers: headers)

    do {
      try await fixture.service.remove(id: fixture.activeEndpointID)
      Issue.record("removing the only endpoint should fail")
    } catch let error as AccountEndpointError {
      #expect(error == .lastAddress)
    }
    let added = try await fixture.service.add(
      url: candidateURL, customHeaders: ["X-Candidate-Proxy": "candidate-secret"])
    do {
      try await fixture.service.remove(id: fixture.activeEndpointID)
      Issue.record("removing the active endpoint should fail")
    } catch let error as AccountEndpointError {
      #expect(error == .activeAddress)
    }
    try await fixture.service.remove(id: try #require(added.id))
    #expect(try headers.load(for: activeURL)?.headers == ["X-Existing-Proxy": "existing-secret"])
    #expect(try headers.load(for: candidateURL) == nil)
  }

  @Test("reorder, preference, and endpoint reads use the stored account")
  func endpointOrderingAndPreference() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/api/me", response: profileResponse(userID: userID))
    let fixture = try makeFixture(transport: transport)

    let added = try await fixture.service.add(url: candidateURL, customHeaders: [:])
    let addedID = try #require(added.id)
    try await fixture.service.reorder(ids: [addedID, fixture.activeEndpointID])
    try await fixture.service.setPreferred(id: addedID)

    let endpoints = try await fixture.service.endpoints()
    #expect(endpoints.map(\.id) == [addedID, fixture.activeEndpointID])
    #expect(endpoints.first?.isPreferred == true)
  }

  @Test("add and remove preserve account identity and account-owned row counts")
  func addAndRemovePreserveAccountData() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    await transport.stub(path: "/api/me", response: profileResponse(userID: userID))
    let fixture = try makeFixture(transport: transport)
    try seedAccountOwnedRows(in: fixture.database, accountID: fixture.accountID)
    let before = try accountSnapshot(fixture.database)

    let accountBefore = before.account
    let added = try await fixture.service.add(url: candidateURL, customHeaders: [:])
    try await fixture.service.remove(id: try #require(added.id))
    let after = try accountSnapshot(fixture.database)

    #expect(after.account == accountBefore)
    #expect(after.counts == before.counts)
  }

  private struct Fixture: Sendable {
    let service: AccountEndpointService
    let database: AppDatabase
    let tokenStore: InMemoryTokenStore
    let endpointDAO: AccountEndpointDAO
    let accountID: Int64
    let activeEndpointID: Int64
    let tokenAccount: TokenAccount
    let now: Date
  }

  private func makeFixture(
    transport: ScriptedAccountTransport,
    headers: any CustomHeaderStoring = InMemoryCustomHeaderStore(),
    storeTokens: Bool = true,
    storedTokens: TokenPair = TokenPair(accessToken: "old-access", refreshToken: "old-refresh"),
    refreshLiveTokens: @escaping @Sendable (TokenAccount) async throws -> TokenPair = { _ in
      throw APIError.transport
    },
    loginBackoffGate: LoginBackoffGate = LoginBackoffGate()
  ) throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let accountDAO = AccountDAO(database: database)
    var account = AccountRecord(
      clientUUID: "stable-client",
      credentialNamespace: "account:stable-client",
      serverBaseURL: activeURL.absoluteString,
      serverUserId: userID,
      serverVersion: "2.36.0")
    account = try accountDAO.save(account)
    let accountID = try #require(account.id)
    let endpointDAO = AccountEndpointDAO(database: database)
    let activeEndpoint = try endpointDAO.insert(
      accountId: accountID, normalizedURL: activeURL.absoluteString, preferred: true)
    let tokenAccount = try account.credentialTokenAccount
    let tokenStore = InMemoryTokenStore()
    if storeTokens {
      try tokenStore.save(storedTokens, for: tokenAccount)
    }
    let now = Date(timeIntervalSince1970: 42)
    let service = AccountEndpointService(
      accountDAO: accountDAO,
      accountEndpointDAO: endpointDAO,
      tokenStore: tokenStore,
      customHeaderStore: headers,
      serverConfigFactory: ABSServerConfigFactory(customHeaderStore: headers),
      candidateClientFactory: { config, tokenStore in
        ABSClient(
          server: config,
          httpClient: transport,
          tokenStore: tokenStore,
          customHeaderStore: headers)
      },
      refreshLiveTokens: refreshLiveTokens,
      loginBackoffGate: loginBackoffGate,
      now: { now })
    return Fixture(
      service: service,
      database: database,
      tokenStore: tokenStore,
      endpointDAO: endpointDAO,
      accountID: accountID,
      activeEndpointID: try #require(activeEndpoint.id),
      tokenAccount: tokenAccount,
      now: now)
  }

  private func profileResponse(userID: String) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: [:],
      body: Data("{\"id\":\"\(userID)\",\"librariesAccessible\":[]}".utf8))
  }

  private func seedAccountOwnedRows(in database: AppDatabase, accountID: Int64) throws {
    try database.write { db in
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "library-1", mediaType: "book", name: "Books")
      try library.insert(db)
      var item = ItemRecord(
        accountId: accountID,
        libraryId: try #require(library.id),
        serverItemId: "item-1",
        mediaKind: "book",
        title: "Book",
        sortTitle: "Book")
      try item.insert(db)
      let itemID = try #require(item.id)
      var progress = MediaProgressRecord(
        accountId: accountID,
        itemId: itemID,
        currentTime: 10,
        isFinished: false,
        localSequence: 1,
        origin: .local,
        originKey: "stable-client")
      try progress.insert(db)
      var session = PlaybackSessionRecord(
        accountId: accountID,
        clientSessionId: "session-1",
        itemId: itemID,
        startedAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 1))
      try session.insert(db)
      var download = DownloadRecord(
        accountId: accountID,
        itemId: itemID,
        serverFileIno: "file-1",
        orderIndex: 0,
        destinationRelativePath: "book/file.m4b",
        expectedBytes: 10,
        expectedMimeType: "audio/mp4",
        fileDurationSeconds: 10)
      try download.insert(db)
      var queue = ListeningQueueEntryRecord(accountId: accountID, itemId: itemID, position: 0)
      try queue.insert(db)
      var outbox = OutboxOperationRecord(
        accountId: accountID,
        clientOperationId: "operation-1",
        entityKey: "item-1",
        podcastEpisodeId: nil,
        operationKind: "progress",
        coalescingKey: "item-1",
        payloadVersion: 1,
        localSequence: 1,
        playbackSessionId: session.id)
      try outbox.insert(db)
    }
  }

  private func accountSnapshot(_ database: AppDatabase) throws -> (
    account: AccountRecord?, counts: [String: Int]
  ) {
    try database.read { db in
      let account = try AccountRecord.fetchOne(db)
      let tables = [
        "library", "mediaProgress", "playbackSession", "download", "listeningQueueEntry",
        "outboxOperation",
      ]
      var counts: [String: Int] = [:]
      for table in tables {
        counts[table] =
          try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM \(table) WHERE accountId = ?", arguments: [account?.id ?? 0])
          ?? 0
      }
      return (account, counts)
    }
  }
}

private actor TokenAccountRecorder {
  private(set) var values: [TokenAccount] = []

  func record(_ account: TokenAccount) {
    values.append(account)
  }
}
