import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Cross-layer offline/recovery journeys over a real on-disk `AppDatabase`, a real
/// `AccountDAO`/`DownloadStore`/`DownloadFileStore` (with a genuinely completed download file),
/// a real `ABSClient` over a scripted transport (`SessionScriptedHTTPClient`, shared across this
/// target), and real `AccountLifecycleService`/`AccountRemovalCoordinator`/`DownloadCoordinator`/
/// `ResolutionCenter`/`OutboxDrainer`/`PlaybackSessionCoordinator`.
/// `tokenStore`/`server`/`account` persist across incarnations (the Keychain survives a relaunch);
/// everything else is rebuilt, including `AuthenticatedHTTPClient`'s in-memory rejection latch, so
/// a relaunch gets one fresh attempt before latching again.
@Suite("Auth recovery journeys (PRODUCT journey 6)")
struct AuthRecoveryJourneyTests {

  // MARK: - 1. Transient refresh outage

  @Test(
    "a transient refresh outage retains tokens, the account row, and every download row/file, and isAuthenticated stays true"
  )
  func transientRefreshOutageRetainsTokensAccountDownloadsAndNavigation() async throws {
    let env = try await AuthRecoveryJourneyEnvironment()
    let inc = try env.openIncarnation()

    // The reactive path: a resource 401, then the refresh call itself fails transport-only (no
    // stub for /auth/refresh, so the scripted fake throws `NoStubbedResponse`, which
    // `AuthenticatedHTTPClient.classifyTransportFailure` maps to `.transport`).
    await inc.http.stub(path: "/api/items/x", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    let request = try RequestBuilder(server: env.server).makeRequest(
      method: .get, path: "/api/items/x", routeTemplate: "/api/items/x")

    await #expect(throws: (any Error).self) {
      _ = try await inc.client.authenticatedSend(
        request, account: env.account, initialTokens: try #require(try env.tokenStore.load(for: env.account)))
    }

    #expect(try env.tokenStore.load(for: env.account) != nil, "tokens are retained - never cleared")
    #expect(try inc.accountDAO.fetch() != nil, "the account row survives untouched")
    #expect(try env.fetchDownloads(inc).allSatisfy { $0.state == .completed }, "download rows are untouched")
    #expect(FileManager.default.fileExists(atPath: env.downloadedFileURL.path), "the download's file survives")
    #expect(
      inc.lifecycle.isAuthenticated, "RootModel.presentation keys directly off this - shell would still be chosen")
    let events = await inc.authObserver.events
    #expect(
      events == [.refreshTransport(env.account)],
      "a transport-only outage emits diagnostics without requesting reauthentication")
  }

  // MARK: - 2. Rejected refresh keeps a completed download playable

  @Test("a rejected refresh (definitive latch) still resolves and plays a completed local download")
  func rejectedRefreshKeepsCompletedDownloadPlayable() async throws {
    let env = try await AuthRecoveryJourneyEnvironment()
    let inc = try env.openIncarnation()
    try await env.latchDefiniteRejection(inc)

    let playback = PlaybackSessionCoordinator(
      client: inc.client, database: inc.database, outbox: inc.outbox, downloadStore: inc.downloadStore,
      downloadFileStore: inc.downloadFileStore)
    let prepared = try await playback.startSession(itemID: AuthRecoveryJourneyEnvironment.itemID, episodeID: nil)

    #expect(prepared.source == .local, "resolves the completed local copy - never touches the latched network client")
    #expect(FileManager.default.fileExists(atPath: env.downloadedFileURL.path))
  }

  // MARK: - 3. Progress created while latched drains after recovery

  @Test("progress written while latched persists durably and drains once reauthentication succeeds")
  func progressCreatedDuringReauthenticationDrainsAfterRecovery() async throws {
    let env = try await AuthRecoveryJourneyEnvironment()
    let inc = try env.openIncarnation()
    try await env.latchDefiniteRejection(inc)

    // Written while latched: enqueue is a local DB write and never touches the network.
    let operation = try inc.outbox.enqueueProgress(
      accountId: env.accountId, entityKey: AuthRecoveryJourneyEnvironment.itemID, podcastEpisodeId: nil,
      coalescingKey: "auth-recovery-progress", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 42, isFinished: false, accumulatedDeltaSeconds: 5))
    let operationId = try #require(operation.id)

    await inc.outboxDrainer.drainOutbox(now: Date())
    var record = try await inc.database.readAsync { db in try OutboxOperationRecord.fetchOne(db, key: operationId) }
    #expect(record?.state == .pending, "a latched client refuses locally - the row waits, never dead-lettered")
    #expect(record?.deadLetterReason == nil)

    // Recovery: same-account reauthentication succeeds through the shared live client.
    await inc.http.stub(
      path: "/login",
      responses: [
        AuthRecoveryJourneyEnvironment.loginResponse(
          userID: AuthRecoveryJourneyEnvironment.serverUserId, accessToken: "recovered-access",
          refreshToken: "recovered-refresh")
      ])
    try await inc.lifecycle.reauthenticate(username: "rhys", password: "hunter2")
    try await inc.resolutionCenter.handleSuccessfulReauthentication()

    record = try await inc.database.readAsync { db in try OutboxOperationRecord.fetchOne(db, key: operationId) }
    #expect(record?.state == .pending, "recovery leaves the retained row queued")

    // A subsequent drain, now unlatched, actually lands it.
    await inc.http.stub(
      path: "/api/me/progress/\(AuthRecoveryJourneyEnvironment.itemID)",
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    await inc.outboxDrainer.drainOutbox(now: Date())
    #expect(
      try inc.outbox.fetchQueued(accountId: env.accountId, entityKey: AuthRecoveryJourneyEnvironment.itemID).isEmpty)
  }

  // MARK: - 4. Same-account recovery preserves identity

  @Test("same-account recovery leaves the account id, clientUUID, download rows, and files untouched")
  func sameAccountRecoveryPreservesAccountIdDownloadRowsAndFiles() async throws {
    let env = try await AuthRecoveryJourneyEnvironment()
    let inc = try env.openIncarnation()
    try await env.latchDefiniteRejection(inc)

    let beforeAccount = try #require(try inc.accountDAO.fetch())
    let beforeDownloads = try env.fetchDownloads(inc)

    await inc.http.stub(
      path: "/login",
      responses: [
        AuthRecoveryJourneyEnvironment.loginResponse(
          userID: AuthRecoveryJourneyEnvironment.serverUserId, accessToken: "recovered-access",
          refreshToken: "recovered-refresh")
      ])
    try await inc.lifecycle.reauthenticate(username: "rhys", password: "hunter2")

    let afterAccount = try #require(try inc.accountDAO.fetch())
    #expect(afterAccount.id == beforeAccount.id)
    #expect(afterAccount.clientUUID == beforeAccount.clientUUID)
    #expect(afterAccount.serverUserId == beforeAccount.serverUserId)
    let afterDownloads = try env.fetchDownloads(inc)
    #expect(afterDownloads == beforeDownloads)
    #expect(FileManager.default.fileExists(atPath: env.downloadedFileURL.path))
    #expect(try env.tokenStore.load(for: env.account)?.accessToken == "recovered-access")

    // The client is usable again immediately, with no rebuild.
    await inc.http.stub(
      path: "/api/items/y", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let request = try RequestBuilder(server: env.server).makeRequest(
      method: .get, path: "/api/items/y", routeTemplate: "/api/items/y")
    let response = try await inc.client.authenticatedSend(
      request, account: env.account, initialTokens: try #require(try env.tokenStore.load(for: env.account)))
    #expect(response.statusCode == 200)
  }

  // MARK: - 5. Different user cannot adopt existing account data

  @Test("a different returned user is refused without mutating tokens, the account row, or downloads")
  func differentUserCannotAdoptExistingAccountData() async throws {
    let env = try await AuthRecoveryJourneyEnvironment()
    let inc = try env.openIncarnation()
    try await env.latchDefiniteRejection(inc)

    let beforeAccount = try #require(try inc.accountDAO.fetch())
    let beforeDownloads = try env.fetchDownloads(inc)
    let beforeTokens = try env.tokenStore.load(for: env.account)

    await inc.http.stub(
      path: "/login",
      responses: [
        AuthRecoveryJourneyEnvironment.loginResponse(userID: "a-different-user", accessToken: "x", refreshToken: "y")
      ])

    await #expect(throws: AccountLifecycleError.accountMismatch) {
      try await inc.lifecycle.reauthenticate(username: "rhys", password: "hunter2")
    }

    let afterAccount = try #require(try inc.accountDAO.fetch())
    #expect(afterAccount == beforeAccount, "nothing about the local account row moved")
    #expect(try env.fetchDownloads(inc) == beforeDownloads)
    #expect(try env.tokenStore.load(for: env.account) == beforeTokens, "the original pair is untouched")
    let mismatchedAccount = try TokenAccount(
      serverURL: URL(string: AuthRecoveryJourneyEnvironment.serverBaseURL)!, userID: "a-different-user")
    #expect(try env.tokenStore.load(for: mismatchedAccount) == nil, "no tokens are ever saved for the wrong user")
    // Still latched: a mismatched reauthentication does not clear the rejection latch. The next
    // call fails locally as `.unauthorized` with no network traffic (no stub is registered for
    // this path, so a network attempt would throw a different, unstubbed-path error).
    let stillLatchedRequest = try RequestBuilder(server: env.server).makeRequest(
      method: .get, path: "/api/items/still-latched", routeTemplate: "/api/items/still-latched")
    await #expect(throws: APIError.unauthorized) {
      _ = try await inc.client.authenticatedSend(
        stillLatchedRequest, account: env.account,
        initialTokens: try #require(try env.tokenStore.load(for: env.account)))
    }
  }

  // MARK: - 6. Explicit confirmed logout still purges everything

  @Test("explicit confirmed logout still purges tokens, the account row, and every download file")
  func explicitConfirmedLogoutStillPurgesEverything() async throws {
    let env = try await AuthRecoveryJourneyEnvironment()
    let inc = try env.openIncarnation(withRemovalCoordinator: true)
    await inc.http.stub(path: "/logout", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    try await inc.lifecycle.logout()

    #expect(try inc.accountDAO.fetch() == nil, "the account row, and every row it owned, is gone")
    #expect(try env.tokenStore.load(for: env.account) == nil)
    #expect(
      FileManager.default.fileExists(atPath: env.downloadedFileURL.path) == false,
      "the downloaded book's file is gone")
    #expect(
      FileManager.default.fileExists(atPath: env.downloadsAccountRootURL.path) == false,
      "the whole per-account downloads directory is gone")
  }

  // MARK: - 7. Relaunch with a rejected stored pair

  @Test("a fresh composition with a stored pair enters the shell, then latches on its first authenticated request")
  func relaunchWithRejectedStoredPairEntersShellThenRequestsRecovery() async throws {
    let env = try await AuthRecoveryJourneyEnvironment()
    // First incarnation only persists the account row/tokens (already seeded by the environment).
    _ = try env.openIncarnation()

    // The relaunch: a new object graph over the same tokenStore/account row (Keychain/DB survive
    // a relaunch). `isAuthenticated` must already be true before any network call.
    let second = try env.openIncarnation()
    #expect(second.lifecycle.isAuthenticated, "a fresh composition with a stored pair enters the shell directly")

    // First authenticated request: refresh itself comes back 401 (a definitive rejection).
    await second.http.stub(
      path: "/api/items/x", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await second.http.stub(
      path: "/auth/refresh", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    let request = try RequestBuilder(server: env.server).makeRequest(
      method: .get, path: "/api/items/x", routeTemplate: "/api/items/x")

    await #expect(throws: APIError.unauthorized) {
      _ = try await second.client.authenticatedSend(
        request, account: env.account, initialTokens: try #require(try env.tokenStore.load(for: env.account)))
    }

    let events = await second.authObserver.events
    #expect(
      events == [.reauthenticationRequired(env.account)], "exactly one recovery-required event, in the new incarnation")
    #expect(second.lifecycle.isAuthenticated, "still true - a rejected refresh never clears tokens")
  }

  // MARK: - 8. Background refresh and foreground sync share one refresh/recovery event

  @Test("two concurrent callers through the same shared client see exactly one refresh and one recovery event")
  func backgroundRefreshAndForegroundSyncShareOneRefreshAndRecoveryEvent() async throws {
    let env = try await AuthRecoveryJourneyEnvironment()
    let inc = try env.openIncarnation()

    await inc.http.stub(
      path: "/api/items/background", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await inc.http.stub(
      path: "/api/items/foreground", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    // A single refresh response: coalescing means only one of the two 401s should ever trigger it.
    await inc.http.stub(path: "/auth/refresh", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])

    let backgroundRequest = try RequestBuilder(server: env.server).makeRequest(
      method: .get, path: "/api/items/background", routeTemplate: "/api/items/background")
    let foregroundRequest = try RequestBuilder(server: env.server).makeRequest(
      method: .get, path: "/api/items/foreground", routeTemplate: "/api/items/foreground")
    let tokens = try #require(try env.tokenStore.load(for: env.account))
    let client = inc.client
    let account = env.account

    async let backgroundResult: Void = {
      _ = try? await client.authenticatedSend(backgroundRequest, account: account, initialTokens: tokens)
    }()
    async let foregroundResult: Void = {
      _ = try? await client.authenticatedSend(foregroundRequest, account: account, initialTokens: tokens)
    }()
    _ = await (backgroundResult, foregroundResult)

    #expect(await inc.http.requestCount(forPath: "/auth/refresh") == 1, "exactly one shared refresh")
    let events = await inc.authObserver.events
    #expect(events == [.reauthenticationRequired(env.account)], "exactly one recovery-required event")
  }
}

// MARK: - Environment / incarnation harness

/// One journey's fixed identity (server/account/item/download), backed by a single temp-file
/// database and a single temp downloads root.
/// `tokenStore`/`server`/`account` are environment-level (they persist across incarnations, as
/// the Keychain survives a relaunch); `openIncarnation()` rebuilds every in-memory object graph,
/// including `AuthenticatedHTTPClient`'s rejection latch.
private final class AuthRecoveryJourneyEnvironment: @unchecked Sendable {
  static let itemID = "item_auth_recovery_fixture"
  static let libraryID = "lib-auth-recovery"
  static let serverUserId = "user-1"
  static let serverBaseURL = "https://auth-recovery.example.test"

  let databaseURL: URL
  let downloadsRootURL: URL
  let downloadsAccountRootURL: URL
  let downloadedFileURL: URL
  let server: ABSServerConfig
  let account: TokenAccount
  let tokenStore: InMemoryTokenStore
  let clientUUID: String
  let accountId: Int64
  let itemRowId: Int64

  private let fixture: SuiteOnDiskDatabases
  private let scope: OnDiskDatabaseScope
  private var currentDatabase: AppDatabase?

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "AuthRecoveryJourneyEnvironment")
    self.fixture = fixture
    scope = fixture.scope
    databaseURL = scope.url()
    downloadsRootURL = scope.directoryURL.appendingPathComponent("Downloads", isDirectory: true)

    server = try ABSServerConfig(url: try #require(URL(string: Self.serverBaseURL)))
    let localClientUUID = UUID().uuidString
    clientUUID = localClientUUID
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: localClientUUID),
      userID: Self.serverUserId)
    tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "original-access", refreshToken: "original-refresh"), for: account)

    let seedDatabase = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    let saved = try await seedDatabase.writeAsync { db in
      var record = AccountRecord(
        clientUUID: localClientUUID, serverBaseURL: Self.serverBaseURL, serverUserId: Self.serverUserId,
        serverVersion: "2.35.1")
      try record.insert(db)
      return record
    }
    let localAccountId = try #require(saved.id)
    let libraryRowId = try await seedDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: Self.libraryID, mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: seedDatabase)
    let localItemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryRowId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Recovery Book", sortTitle: "recovery book")
      ).id)
    accountId = localAccountId
    itemRowId = localItemRowId

    // A genuinely completed download, not a bare placeholder file.
    let downloadStore = try DownloadStore(database: seedDatabase)
    let downloadFileStore = try DownloadFileStore(
      rootURL: downloadsRootURL, fileAttributes: InertFileAttributes(), downloadStore: downloadStore)
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: localAccountId, itemId: localItemRowId, podcastEpisodeId: nil, orderIndex: 0,
      serverFileIno: "ino-1", mimeType: "audio/mpeg")
    let record = try downloadStore.enqueue(
      accountId: localAccountId, itemId: localItemRowId, serverFileIno: "ino-1", orderIndex: 0,
      destinationRelativePath: relativePath, expectedBytes: 10, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: 60)
    let downloadId = try #require(record.id)
    _ = try await downloadStore.transitionAsync(downloadId: downloadId, to: .downloading)
    let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x1, count: 10).write(to: tempFile)
    _ = try downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: tempFile,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 10))

    downloadedFileURL = downloadFileStore.absoluteURL(forRelativePath: relativePath)
    downloadsAccountRootURL = downloadsRootURL.appendingPathComponent("\(localAccountId)", isDirectory: true)
    scope.close(seedDatabase)
  }

  deinit {}

  struct Incarnation {
    let database: AppDatabase
    let http: SessionScriptedHTTPClient
    let authObserver: RecordingAuthEventObserving
    let client: ABSClient
    let outbox: OutboxStore
    let outboxDrainer: OutboxDrainer
    let downloadStore: DownloadStore
    let downloadFileStore: DownloadFileStore
    let downloadCoordinator: DownloadCoordinator
    let accountDAO: AccountDAO
    let lifecycle: AccountLifecycleService
    let resolutionCenter: ResolutionCenter
  }

  /// One "process lifetime": a fresh `AppDatabase` connection, a fresh scripted transport, a fresh
  /// `ABSClient`/`AuthenticatedHTTPClient` (so its in-memory rejection latch always starts clear),
  /// and a fresh `AccountLifecycleService`/`ResolutionCenter`/`DownloadCoordinator` wired against
  /// that same client. Reauthentication replaces tokens inside the shared live client, so every
  /// caller in one incarnation must share one `ABSClient`, as in `AppEnvironment`.
  func openIncarnation(withRemovalCoordinator: Bool = false) throws -> Incarnation {
    if let currentDatabase {
      scope.close(currentDatabase)
      self.currentDatabase = nil
    }
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    currentDatabase = database
    let http = SessionScriptedHTTPClient()
    let authObserver = RecordingAuthEventObserving()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore, authEventObserving: authObserver)

    let accountDAO = AccountDAO(database: database)
    let outbox = try OutboxStore(database: database)
    let downloadStore = try DownloadStore(database: database)
    let downloadFileStore = try DownloadFileStore(
      rootURL: downloadsRootURL, fileAttributes: InertFileAttributes(), downloadStore: downloadStore)
    let downloadCoordinator = DownloadCoordinator.make(
      client: client, database: database, downloadStore: downloadStore, downloadFileStore: downloadFileStore,
      backgroundTransferring: FakeBackgroundTransferring(), downloadPreferences: FakeDownloadPreferences(),
      networkConditions: FakeNetworkConditions(), diagnostics: FakeDiagnosticsRecording(),
      freeSpaceReporting: FakeFreeSpaceReporting())

    let outboxDrainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId)

    var removalCoordinator: AccountRemovalCoordinator?
    if withRemovalCoordinator {
      removalCoordinator = AccountRemovalCoordinator(
        tokenStore: tokenStore, accountDAO: accountDAO,
        accountEndpointDAO: AccountEndpointDAO(database: database),
        journalStore: AccountRemovalJournalStore(database: database),
        accountRemover: AccountRemover(database: database), clientFactory: { _, _ in client },
        downloadsRootURL: downloadsRootURL)
    }
    let lifecycle = AccountLifecycleService(
      tokenStore: tokenStore, accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      accountRemover: AccountRemover(database: database),
      clientFactory: { _, _ in client }, removalCoordinator: removalCoordinator)

    let resolutionCenter = ResolutionCenter(
      database: database, outboxStore: outbox, downloadStore: downloadStore, downloadCoordinator: downloadCoordinator,
      client: client)

    return Incarnation(
      database: database, http: http, authObserver: authObserver, client: client, outbox: outbox,
      outboxDrainer: outboxDrainer, downloadStore: downloadStore, downloadFileStore: downloadFileStore,
      downloadCoordinator: downloadCoordinator, accountDAO: accountDAO, lifecycle: lifecycle,
      resolutionCenter: resolutionCenter)
  }

  /// Drives a definitive rejection through the reactive path (a resource 401, refresh itself 401)
  /// so a test can start from an already-latched client. The latch mechanics are covered in
  /// `ABSApiTests` (`RefreshTests`/`AuthEventObservingTests`).
  func latchDefiniteRejection(_ inc: Incarnation) async throws {
    await inc.http.stub(
      path: "/api/items/latch-trigger", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await inc.http.stub(path: "/auth/refresh", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    let request = try RequestBuilder(server: server).makeRequest(
      method: .get, path: "/api/items/latch-trigger", routeTemplate: "/api/items/latch-trigger")
    await #expect(throws: APIError.unauthorized) {
      _ = try await inc.client.authenticatedSend(
        request, account: account, initialTokens: try #require(try tokenStore.load(for: account)))
    }
  }

  func fetchDownloads(_ inc: Incarnation) throws -> [DownloadRecord] {
    try inc.downloadStore.fetchDownloads(itemId: itemRowId)
  }

  static func loginResponse(userID: String, accessToken: String, refreshToken: String) -> HTTPResponse {
    let body = try! JSONSerialization.data(
      withJSONObject: [
        "user": ["id": userID, "accessToken": accessToken, "refreshToken": refreshToken],
        "userDefaultLibraryId": NSNull(),
      ])
    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
  }
}

/// Records every `AuthEvent` in arrival order. Duplicates the private fake in
/// `ABSApiTests.AuthEventObservingTests`, which another test target cannot see.
private actor RecordingAuthEventObserving: AuthEventObserving {
  private(set) var events: [AuthEvent] = []

  func authEvent(_ event: AuthEvent) async {
    events.append(event)
  }
}
