import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The full confirmed account-removal sequence, one test per step.
/// `AccountRemovalCrashRecoveryTests` is the crash-boundary companion to this suite.
@Suite struct AccountRemovalWorkflowTests {

  @Test func cancellingAtTheWarningWritesNoJournalAndLeavesEverythingIntact() async throws {
    let harness = try AccountRemovalTestHarness()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)
    let coordinator = harness.makeCoordinator(database: database)

    // "Cancelling at the warning" is simply never calling `confirmRemoval()`. AppModel's
    // confirmation copy is what would have called it.

    #expect(try await coordinator.isRemovalPending() == false)
    #expect(try harness.fetchAccountRow(database: database)?.id == accountId)
    #expect(try harness.hasStoredTokens())
    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path))
  }

  @Test func confirmedRemovalWritesTheJournalDurablyBeforeAnyDestructiveSideEffect() async throws {
    let harness = try AccountRemovalTestHarness()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)
    let coordinator = harness.makeCoordinator(database: database)
    await coordinator.setCrashAfterStepForTesting(.journalWritten)

    await #expect(throws: AccountRemovalCoordinator.SimulatedCrashForTesting.self) {
      try await coordinator.confirmRemoval()
    }

    #expect(try await coordinator.isRemovalPending(), "the journal must exist the instant it is written")
    // Nothing destructive has happened yet: the journal write is the first durable step, before
    // playback quiesce, sync/transfer cancellation, server logout, token wipe, or any deletion.
    #expect(try harness.fetchAccountRow(database: database)?.id == accountId)
    #expect(try harness.hasStoredTokens())
    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path))
  }

  @Test func confirmedRemovalRunsTheFullSequenceInSYNCSPECOrderAndReturnsToSetup() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)
    let playback = FakePlaybackSyncing()
    let cancelSyncCalls = TestCounter()
    let coordinator = harness.makeCoordinator(
      database: database,
      playback: playback,
      cancelForegroundSync: { cancelSyncCalls.increment() }
    )

    try await coordinator.confirmRemoval()

    #expect(
      await coordinator.recordedStepsForTesting() == [
        .journalWritten, .intentsStopped, .quiesced, .transfersCancelled, .serverLogoutAttempted,
        .filesRemoved, .dbRemovedAndVerified, .journalCleared,
      ])
    #expect(playback.calls.contains(.quiesceForLogout))
    #expect(cancelSyncCalls.value == 1)
    #expect(await harness.transport.requests.contains { $0.url.path == "/logout" })
    #expect(try harness.hasStoredTokens() == false)
    #expect(try harness.fetchAccountRow(database: database) == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path) == false)
    #expect(FileManager.default.fileExists(atPath: harness.coverCacheRootURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: harness.exportedDiagnosticsRootURL.path) == false)
    for root in harness.widgetRootURLs {
      #expect(FileManager.default.fileExists(atPath: root.path) == false)
    }
    #expect(try await coordinator.isRemovalPending() == false, "returned to setup")
  }

  /// The pending-removal graph supplies no playback, transfer engine, sync shutdown or outbox
  /// drain. Removal must still reach setup from its filesystem roots alone. The client factory
  /// stands in for the pending path's production factory, which the test host cannot reach.
  @Test func theInertCompositionCompletesTheFullSequenceWithNoLiveCollaborators() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)
    let coordinator = harness.makeCoordinator(database: database)

    try await coordinator.confirmRemoval()

    #expect(
      await coordinator.recordedStepsForTesting() == [
        .journalWritten, .intentsStopped, .quiesced, .transfersCancelled, .serverLogoutAttempted,
        .filesRemoved, .dbRemovedAndVerified, .journalCleared,
      ])
    #expect(try harness.hasStoredTokens() == false)
    #expect(try harness.fetchAccountRow(database: database) == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path) == false)
    #expect(try await coordinator.isRemovalPending() == false, "returned to setup")
  }

  @Test func removalClearsTheNamespaceItemAndEveryEndpointsLegacyAndHeaderItems() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database)
    let account = try #require(try harness.fetchAccountRow(database: database))
    let endpointDAO = AccountEndpointDAO(database: database)
    let endpointURLs = [
      account.serverBaseURL,
      "https://lan.books.example.test:8443/abs",
    ]
    _ = try endpointDAO.insert(accountId: accountId, normalizedURL: endpointURLs[0], preferred: true)
    _ = try endpointDAO.insert(accountId: accountId, normalizedURL: endpointURLs[1], preferred: false)
    let headerStore = InMemoryCustomHeaderStore()
    let legacyTokens = TokenPair(accessToken: "legacy-access", refreshToken: "legacy-refresh")

    for endpointURL in endpointURLs {
      let url = try #require(URL(string: endpointURL))
      try harness.tokenStore.save(
        legacyTokens,
        for: TokenAccount(serverURL: url, userID: account.serverUserId))
      try headerStore.save(CustomHeaders(["X-Proxy-Token": "header-secret"]), for: url)
    }
    let coordinator = harness.makeCoordinator(
      database: database, customHeaderStore: headerStore)

    try await coordinator.confirmRemoval()

    #expect(try harness.tokenStore.load(for: account.credentialTokenAccount) == nil)
    for endpointURL in endpointURLs {
      let url = try #require(URL(string: endpointURL))
      #expect(
        try harness.tokenStore.load(
          for: TokenAccount(serverURL: url, userID: account.serverUserId)) == nil)
      #expect(try headerStore.load(for: url) == nil)
    }
  }

  /// Removal drops the live graph but cannot stop whatever still retains its client. Once the next
  /// account's pair is in the shared store, that retained client must not send it to the removed
  /// account's server, and must not refresh it there.
  @Test func aClientHeldPastRemovalCannotServeTheNextAccount() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let removed = try #require(try harness.fetchAccountRow(database: database))
    let server = try ABSServerConfig(url: try #require(URL(string: harness.serverBaseURL)))
    let retained = ABSClient(
      server: server, httpClient: harness.transport, tokenStore: harness.tokenStore,
      boundAccount: try removed.credentialTokenAccount)
    let coordinator = harness.makeCoordinator(database: database, client: retained)

    try await coordinator.confirmRemoval()

    // The next sign-in gets a fresh client UUID, and so a credential namespace of its own.
    let next = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: UUID().uuidString),
      userID: "user-2")
    let nextTokens = TokenPair(accessToken: "next-access", refreshToken: "next-refresh")
    try harness.tokenStore.save(nextTokens, for: next)
    let requestsAfterRemoval = await harness.transport.requests.count

    await #expect(throws: APIError.cancelled) {
      _ = try await retained.listLibraries(account: next)
    }
    await #expect(throws: APIError.cancelled) {
      _ = try await retained.refreshTokens(for: next)
    }

    #expect(await harness.transport.requests.count == requestsAfterRemoval)
    #expect(try harness.tokenStore.load(for: next) == nextTokens)
  }

  @Test func preV63JournalWithoutNamespaceStillClearsThroughTheURL() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database)
    let account = try #require(try harness.fetchAccountRow(database: database))
    let legacyAccount = try TokenAccount(
      serverURL: try #require(URL(string: account.serverBaseURL)), userID: account.serverUserId)
    try harness.tokenStore.clear(for: account.credentialTokenAccount)
    try harness.tokenStore.save(
      TokenPair(accessToken: "legacy-access", refreshToken: "legacy-refresh"), for: legacyAccount)
    let headerStore = InMemoryCustomHeaderStore()
    let serverURL = try #require(URL(string: account.serverBaseURL))
    try headerStore.save(CustomHeaders(["X-Proxy-Token": "legacy-header"]), for: serverURL)
    try await AccountRemovalJournalStore(database: database).createAsync(
      AccountRemovalJournalRecord(
        serverBaseURL: account.serverBaseURL,
        serverUserId: account.serverUserId,
        accountRowId: accountId,
        downloadsRootRelativePath: String(accountId),
        createdAt: Date()))
    let coordinator = harness.makeCoordinator(
      database: database, customHeaderStore: headerStore)

    try await coordinator.confirmRemoval()

    #expect(try harness.tokenStore.load(for: legacyAccount) == nil)
    #expect(try headerStore.load(for: serverURL) == nil)
  }

  @Test func malformedEndpointURLBlocksBeforeAnythingIsCleared() async throws {
    let harness = try AccountRemovalTestHarness()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database)
    let account = try #require(try harness.fetchAccountRow(database: database))
    let serverURL = try #require(URL(string: account.serverBaseURL))
    let legacyAccount = try TokenAccount(serverURL: serverURL, userID: account.serverUserId)
    try harness.tokenStore.save(
      TokenPair(accessToken: "legacy-access", refreshToken: "legacy-refresh"), for: legacyAccount)
    let headerStore = InMemoryCustomHeaderStore()
    try headerStore.save(CustomHeaders(["X-Proxy-Token": "header-secret"]), for: serverURL)
    try await AccountRemovalJournalStore(database: database).createAsync(
      AccountRemovalJournalRecord(
        serverBaseURL: account.serverBaseURL,
        serverUserId: account.serverUserId,
        credentialNamespace: account.credentialNamespace,
        endpointURLs: ["not a valid URL"],
        accountRowId: accountId,
        downloadsRootRelativePath: String(accountId),
        createdAt: Date()))
    let coordinator = harness.makeCoordinator(
      database: database, customHeaderStore: headerStore)

    await #expect(throws: AccountRemovalError.credentialClearFailed) {
      try await coordinator.confirmRemoval()
    }

    #expect(try harness.tokenStore.load(for: account.credentialTokenAccount) != nil)
    #expect(try harness.tokenStore.load(for: legacyAccount) != nil)
    #expect(try headerStore.load(for: serverURL) != nil)
    #expect(try harness.fetchAccountRow(database: database) != nil)
  }

  @Test func aFailedServerLogoutNeverRetainsCredentialsButStillCompletesRemoval() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.transport.stub(
      path: "/logout", response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let coordinator = harness.makeCoordinator(database: database)

    try await coordinator.confirmRemoval()

    #expect(try harness.hasStoredTokens() == false, "a failed server logout never retains credentials")
    #expect(try harness.fetchAccountRow(database: database) == nil)
    #expect(try await coordinator.isRemovalPending() == false, "local removal still completes and clears the journal")
  }

  @Test func headerlessRemovalStillClearsEveryArtworkTier() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let artworkClearCalls = TestCounter()
    let coordinator = harness.makeCoordinator(
      database: database,
      clearCachedArtwork: { artworkClearCalls.increment() })

    try await coordinator.confirmRemoval()

    #expect(artworkClearCalls.value == 1)
  }

  @Test func aStoreThatClaimsToClearButRetainsCredentialsBlocksRemoval() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let stickyStore = StickyClearTokenStore(base: harness.tokenStore)
    let coordinator = harness.makeCoordinator(database: database, tokenStore: stickyStore)

    await #expect(throws: AccountRemovalError.credentialClearFailed) {
      try await coordinator.confirmRemoval()
    }

    #expect(try await coordinator.isRemovalPending())
    #expect(try harness.fetchAccountRow(database: database) != nil)
    #expect(try harness.hasStoredTokens())
  }

  @Test func concurrentCallersJoinOneRemovalFlight() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let cancellationGate = AccountRemovalCancellationGate()
    let coordinator = harness.makeCoordinator(
      database: database,
      cancelForegroundSync: { await cancellationGate.block() })

    let first = Task { try await coordinator.confirmRemoval() }
    await cancellationGate.waitUntilBlocked()
    let second = Task { try await coordinator.resumeIfNeeded() }
    await Task.yield()

    #expect(await cancellationGate.callCount == 1)
    await cancellationGate.release()
    try await first.value
    try await second.value

    #expect(await cancellationGate.callCount == 1)
    #expect(await harness.transport.requests.filter { $0.url.path == "/logout" }.count == 1)
    #expect(try await coordinator.isRemovalPending() == false)
  }

  /// Step 4 wired to a real engine: removal does not reach the credential wipe until the traversal
  /// in flight at confirmation has ended, so that traversal finishes with valid credentials rather
  /// than failing locally after the wipe.
  @Test func removalWaitsForTheDrainedTraversalBeforeWipingCredentials() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let syncTransport = FakeHTTPClient()
    let gate = HeldRequestGate()
    let events = RemovalEventLog()
    syncTransport.setRequestHook { request in
      guard request.url.path == "/api/libraries" else { return }
      await gate.blockFirstRequest()
      events.append((try? harness.hasStoredTokens()) == true ? "response, credentials held" : "response, wiped")
    }
    syncTransport.enqueue(
      Harness.jsonResponse(object: ["libraries": [["id": "lib1", "name": "Library", "mediaType": "book"]]]))
    let engine = SyncEngine.make(
      client: ABSClient(
        server: try ABSServerConfig(url: try #require(URL(string: harness.serverBaseURL))),
        httpClient: syncTransport, tokenStore: harness.tokenStore),
      database: database, diagnostics: FakeDiagnosticsRecording(), appLifecycle: FakeAppLifecycle())
    let coordinator = harness.makeCoordinator(
      database: database,
      cancelForegroundSync: {
        await engine.shutdown()
        events.append("drained")
      })

    let refresh = Task { await engine.refresh() }
    await gate.waitUntilBlocked()
    let removal = Task { try await coordinator.confirmRemoval() }
    await waitUntil { await engine.isShutdown }
    await gate.release()
    try await removal.value
    await refresh.value

    #expect(events.entries == ["response, credentials held", "drained"])
    #expect(syncTransport.requests.map(\.url.path) == ["/api/libraries"])
    #expect(try harness.hasStoredTokens() == false)
    #expect(try harness.fetchAccountRow(database: database) == nil)
  }

  /// The outbox cascades with the account row, so unsent progress gets one bounded chance to
  /// reach the server while the account and its credentials still exist.
  @Test func removalDrainsTheOutboxWhileTheAccountAndCredentialsStillExist() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let events = RemovalEventLog()
    let coordinator = harness.makeCoordinator(
      database: database,
      drainOutboxBeforeRemoval: {
        let hasTokens = (try? harness.hasStoredTokens()) == true
        let hasAccount = (try? harness.fetchAccountRow(database: database)) != nil
        events.append("drain tokens=\(hasTokens) account=\(hasAccount)")
      })

    try await coordinator.confirmRemoval()

    #expect(events.entries == ["drain tokens=true account=true"])
    #expect(try harness.fetchAccountRow(database: database) == nil)
  }

  @Test func aDrainThatNeverFinishesDelaysRemovalOnlyByItsBound() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let gate = HeldRequestGate()
    let coordinator = harness.makeCoordinator(
      database: database,
      drainOutboxBeforeRemoval: { await gate.blockFirstRequest() },
      outboxDrainBound: .milliseconds(50))

    try await coordinator.confirmRemoval()

    #expect(try harness.fetchAccountRow(database: database) == nil)
    #expect(try await coordinator.isRemovalPending() == false)
    await gate.release()
  }

  @Test func aTokenCredentialClearFailureRetainsTheJournalAndRetryCompletes() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let failingStore = ToggleClearTokenStore(base: harness.tokenStore)
    let coordinator = harness.makeCoordinator(database: database, tokenStore: failingStore)

    await #expect(throws: AccountRemovalError.self) {
      try await coordinator.confirmRemoval()
    }

    #expect(try await coordinator.isRemovalPending())
    #expect(try harness.fetchAccountRow(database: database) != nil)
    #expect(try harness.hasStoredTokens())

    failingStore.shouldFailClear = false
    try await coordinator.confirmRemoval()
    #expect(try await coordinator.isRemovalPending() == false)
    #expect(try harness.fetchAccountRow(database: database) == nil)
    #expect(try harness.hasStoredTokens() == false)
  }

  @Test func aHeaderCredentialClearFailureRetainsTheJournalAndRetryCompletes() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let headerStore = ToggleClearHeaderStore()
    try headerStore.save(
      CustomHeaders(["X-Proxy-Token": "header-secret"]),
      for: URL(string: harness.serverBaseURL)!
    )
    let coordinator = harness.makeCoordinator(database: database, customHeaderStore: headerStore)

    await #expect(throws: AccountRemovalError.self) {
      try await coordinator.confirmRemoval()
    }

    #expect(try await coordinator.isRemovalPending())
    #expect(try harness.fetchAccountRow(database: database) != nil)

    headerStore.shouldFailClear = false
    try await coordinator.confirmRemoval()
    #expect(try await coordinator.isRemovalPending() == false)
    #expect(try harness.fetchAccountRow(database: database) == nil)
  }

  @Test func malformedJournalIdentityBlocksBeforeCredentialsOrAccountCanBeOrphaned() async throws {
    let harness = try AccountRemovalTestHarness()
    let database = try harness.openDatabase()
    let accountId = try await harness.seedSignedInAccount(database: database)
    let journalStore = AccountRemovalJournalStore(database: database)
    _ = try await journalStore.createAsync(
      AccountRemovalJournalRecord(
        serverBaseURL: "not a server URL",
        serverUserId: harness.serverUserId,
        accountRowId: accountId,
        downloadsRootRelativePath: String(accountId),
        createdAt: Date()
      ))
    let coordinator = harness.makeCoordinator(database: database)

    await #expect(throws: AccountRemovalError.credentialClearFailed) {
      try await coordinator.confirmRemoval()
    }

    #expect(try harness.hasStoredTokens(), "an unaddressable token must not be silently orphaned")
    #expect(try harness.fetchAccountRow(database: database) != nil)
    #expect(try await coordinator.isRemovalPending())
  }

  /// Forces a real, deterministic local-deletion failure by making the cover-cache directory's
  /// parent undeletable (its own permissions don't matter, as POSIX delete permission lives on the
  /// parent directory entry), then proves the journal survives, blocks, and a later retry
  /// (once the underlying condition is fixed) succeeds.
  @Test func aFailedDeletionLeavesTheJournalPresentBlockingAndRetryableWithADistinctCategory() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let coordinator = harness.makeCoordinator(database: database)

    try FileManager.default.createDirectory(
      at: harness.coverCacheRootURL, withIntermediateDirectories: true)
    let lockedParent = harness.coverCacheRootURL.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedParent.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedParent.path) }

    await #expect(throws: AccountRemovalError.deletionFailed) {
      try await coordinator.confirmRemoval()
    }
    #expect(try await coordinator.isRemovalPending(), "a failed deletion leaves the journal present and blocking")

    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedParent.path)

    // Retryable: calling again re-attempts (and this time succeeds) from the surviving journal.
    try await coordinator.confirmRemoval()
    #expect(try await coordinator.isRemovalPending() == false)
    #expect(FileManager.default.fileExists(atPath: harness.coverCacheRootURL.path) == false)
  }

  @Test func aFailedArtworkPurgeLeavesTheJournalAndAccountForRetry() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let coordinator = harness.makeCoordinator(
      database: database,
      clearCachedArtwork: { throw ArtworkPurgeFailure() })

    await #expect(throws: AccountRemovalError.deletionFailed) {
      try await coordinator.confirmRemoval()
    }

    #expect(try await coordinator.isRemovalPending())
    #expect(try harness.fetchAccountRow(database: database) != nil)
  }

  @Test func logoutWithNoSignedInAccountAndNoJournalIsANoOp() async throws {
    let harness = try AccountRemovalTestHarness()
    let database = try harness.openDatabase()
    let coordinator = harness.makeCoordinator(database: database)

    try await coordinator.confirmRemoval()

    #expect(try await coordinator.isRemovalPending() == false)
  }

  @Test func accountLifecycleServiceLogoutRoutesThroughTheRemovalCoordinatorWhenOneIsSupplied() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let coordinator = harness.makeCoordinator(database: database)
    let service = AccountLifecycleService(
      tokenStore: harness.tokenStore,
      accountDAO: AccountDAO(database: database),
      accountEndpointDAO: AccountEndpointDAO(database: database),
      accountRemover: AccountRemover(database: database),
      clientFactory: { server, tokenStore in
        ABSClient(server: server, httpClient: harness.transport, tokenStore: tokenStore)
      },
      removalCoordinator: coordinator
    )

    try await service.logout()

    #expect(
      await coordinator.recordedStepsForTesting().contains(.dbRemovedAndVerified),
      "logout() delegated to the coordinator's own full sequence, not an inline path")
    #expect(try harness.fetchAccountRow(database: database) == nil)
  }

  @Test func lifecycleDoesNotConvertAPreRemovalJournalBoundaryFailureToRemoteConfirmation() async throws {
    let harness = try AccountRemovalTestHarness()
    let database = try harness.openDatabase()
    try await harness.seedSignedInAccount(database: database)
    let coordinator = harness.makeCoordinator(database: database)
    await coordinator.setCrashAfterStepForTesting(.journalWritten)
    let service = AccountLifecycleService(
      tokenStore: harness.tokenStore,
      accountDAO: AccountDAO(database: database),
      accountEndpointDAO: AccountEndpointDAO(database: database),
      accountRemover: AccountRemover(database: database),
      clientFactory: { server, tokenStore in
        ABSClient(server: server, httpClient: harness.transport, tokenStore: tokenStore)
      },
      removalCoordinator: coordinator
    )

    await #expect(throws: AccountRemovalCoordinator.SimulatedCrashForTesting.self) {
      try await service.logout()
    }

    #expect(try harness.fetchAccountRow(database: database) != nil)
    #expect(try await coordinator.isRemovalPending())
  }
}

private struct ArtworkPurgeFailure: Error {}

private final class RemovalEventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  var entries: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ entry: String) {
    lock.lock()
    storage.append(entry)
    lock.unlock()
  }
}
