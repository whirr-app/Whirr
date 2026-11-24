import Foundation
import GRDB
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

/// Composed end-to-end evidence for auto-download: the real
/// `PodcastSettingsStore`/`PodcastAutoDownloadSelectionStore`/`PodcastAutoDownloadReapStore`/
/// `PodcastAutoDownloadCoordinator`/`PodcastAutoDownloadReaper`/`DownloadCoordinator` composed
/// against an on-disk database, as production wires them (`App/Whirr/AppEnvironment.swift`,
/// `App/Whirr/PodcastBackgroundRefresh.swift`). The lower-level rules (activation floor,
/// candidate predicate, retention exclusions, gating) are pinned by their own unit suites and
/// the trigger-wiring suites (`PodcastAutoDownloadTriggerTests`, `SyncEngineTests`); this file
/// proves the real pieces cooperate.
///
/// Episodes "arrive" by seeding `podcastEpisode` rows directly. Selection is a deterministic
/// database query, not an event hook, so a seeded row and a shelf-committed row are
/// indistinguishable to every store under test.
@MainActor
/// A publication date unambiguously after the activation floor stamped moments earlier by
/// `setShowAutoDownloadOverride`.
///
/// A bare `Date()` would make journeys a coin flip: the floor is stamped when the override is
/// written, and an episode published at the same instant is correctly not a candidate. The
/// boundary is covered by `PersistenceTests/PodcastAutoDownloadSelectionStoreTests`.
private func eligiblePublicationDate() -> Date {
  Date().addingTimeInterval(10)
}

@Suite("Podcast auto-download journeys", .timeLimit(.minutes(1)))
struct PodcastAutoDownloadJourneyTests {

  @Test(
    "enabling a show downloads a new episode automatically; a fourth episode reaps the oldest automatic download while the manual download beside it survives"
  )
  func autoDownloadJourney() async throws {
    let env = try await PodcastAutoDownloadJourneyEnvironment()
    try await env.seedShow(itemID: "show-1")
    let download = try env.makeDownloadHarness()
    let coordinator = env.makeCoordinator(planner: download.coordinator)
    let reaper = env.makeReaper(purging: download.coordinator)

    // Enabling auto-download on the show stamps the activation floor "now".
    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "show-1", override: .enabled)
    let floor = Date()

    // Episode 1 "arrives" (oldest of the four) and is decided automatically.
    try await env.seedEpisode(itemID: "show-1", episodeID: "ep-1", publishedAt: floor.addingTimeInterval(10))
    await coordinator.run()
    try await env.finishPendingDownloads(download, itemID: "show-1")
    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") != nil)
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-1") == .automatic)

    // A manual download beside it: the user tapped this one directly.
    try await env.seedEpisode(itemID: "show-1", episodeID: "ep-2", publishedAt: floor.addingTimeInterval(20))
    try await download.coordinator.requestEpisodeDownload(itemID: "show-1", episodeID: "ep-2")
    try await env.finishPendingDownloads(download, itemID: "show-1")
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-2") == .manual)

    // A third episode, also decided automatically.
    try await env.seedEpisode(itemID: "show-1", episodeID: "ep-3", publishedAt: floor.addingTimeInterval(30))
    await coordinator.run()
    try await env.finishPendingDownloads(download, itemID: "show-1")

    // The fourth episode arrives. Keep-latest defaults to 3, so ep-1 (the oldest of four) is
    // outside the window once this pass reconciles.
    try await env.seedEpisode(itemID: "show-1", episodeID: "ep-4", publishedAt: floor.addingTimeInterval(40))
    await coordinator.run()
    try await env.finishPendingDownloads(download, itemID: "show-1")
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-4") == .automatic)

    await reaper.reap()
    await TestSupport.waitUntil { (try? env.downloadOrigin(itemID: "show-1", episodeID: "ep-1")) == nil }

    #expect(
      try env.downloadOrigin(itemID: "show-1", episodeID: "ep-1") == nil, "the oldest automatic download is reaped")
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-2") == .manual, "the manual download survives")
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-3") == .automatic)
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-4") == .automatic)
    // The reaper never clears the decided stamp, so ep-1 stays decided and is never silently
    // re-downloaded on a later pass.
    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") != nil)
  }

  @Test(
    "a migrated account starts off; enabling global leaves already-known episodes untouched; a show override Off blocks a sibling while an inherited show downloads"
  )
  func migratedAccountRespectsGlobalEnableAndShowOverrides() async throws {
    let env = try await PodcastAutoDownloadJourneyEnvironment()
    try await env.seedShow(itemID: "already-known-show")
    try await env.seedShow(itemID: "blocked-show")
    try await env.seedShow(itemID: "inherited-show")
    let download = try env.makeDownloadHarness()
    let coordinator = env.makeCoordinator(planner: download.coordinator)

    // A migrated account: every table absent means "off"/"inherit", so a pass right now must
    // enqueue nothing at all.
    try await env.seedEpisode(
      itemID: "already-known-show", episodeID: "already-known",
      publishedAt: Date(timeIntervalSince1970: 1_700_000_000))
    await coordinator.run()
    #expect(try env.downloadOrigin(itemID: "already-known-show", episodeID: "already-known") == nil)

    // Enabling the global default must not backfill an episode the account already knew about
    // before the floor. Only episodes published after it are candidates.
    try await env.settingsStore.setGlobalAutoDownloadEnabled(true)
    let globalFloor = Date()
    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "blocked-show", override: .disabled)

    await coordinator.run()
    #expect(
      try env.downloadOrigin(itemID: "already-known-show", episodeID: "already-known") == nil,
      "enabling global never backfills an episode published before the floor")

    // A new episode on the blocked show must never download despite the global default being on.
    try await env.seedEpisode(
      itemID: "blocked-show", episodeID: "blocked-episode",
      publishedAt: globalFloor.addingTimeInterval(10))
    // A sibling show with no override inherits the enabled global default and downloads.
    try await env.seedEpisode(
      itemID: "inherited-show", episodeID: "inherited-episode",
      publishedAt: globalFloor.addingTimeInterval(10))

    await coordinator.run()
    try await env.finishPendingDownloads(download, itemID: "inherited-show")

    #expect(try env.downloadOrigin(itemID: "blocked-show", episodeID: "blocked-episode") == nil)
    #expect(try env.downloadOrigin(itemID: "inherited-show", episodeID: "inherited-episode") == .automatic)
  }

  @Test("a transient planning failure leaves the candidate eligible; a later pass retries and succeeds")
  func transientPlanningFailureRetriesOnALaterPass() async throws {
    let env = try await PodcastAutoDownloadJourneyEnvironment()
    try await env.seedShow(itemID: "show-1")
    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "show-1", override: .enabled)
    try await env.seedEpisode(
      itemID: "show-1", episodeID: "ep-1", publishedAt: eligiblePublicationDate())

    let download = try env.makeDownloadHarness()
    // Fails once, then delegates to the real coordinator. Models both a transient planning
    // error and the "account removed between candidate query and planning" crash cut: either
    // way the candidate must survive undecided for a later pass to retry.
    let flaky = FlakyPlanner(failTimes: 1, underlying: download.coordinator)
    let coordinator = env.makeCoordinator(planner: flaky)

    await coordinator.run()
    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") == nil, "the failed attempt never decides")
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-1") == nil)

    await coordinator.run()
    try await env.finishPendingDownloads(download, itemID: "show-1")
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-1") == .automatic, "the retry succeeds")
    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") != nil)
  }

  @Test("setting a show's auto-download off after planning leaves the row and transfer intact")
  func turningAutoDownloadOffAfterPlanningLeavesTheRowAndTransferIntact() async throws {
    let env = try await PodcastAutoDownloadJourneyEnvironment()
    try await env.seedShow(itemID: "show-1")
    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "show-1", override: .enabled)
    try await env.seedEpisode(
      itemID: "show-1", episodeID: "ep-1", publishedAt: eligiblePublicationDate())

    let download = try env.makeDownloadHarness()
    let coordinator = env.makeCoordinator(planner: download.coordinator)
    let reaper = env.makeReaper(purging: download.coordinator)
    await coordinator.run()
    try await env.finishPendingDownloads(download, itemID: "show-1")
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-1") == .automatic)

    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "show-1", override: .disabled)
    await coordinator.run()
    await reaper.reap()

    // Turning a show off never cancels, pauses or deletes anything by itself. Retention only
    // reaps a keep-latest/delete-after-played violation, neither of which applies here.
    #expect(try env.downloadOrigin(itemID: "show-1", episodeID: "ep-1") == .automatic)
  }

  @Test("logout disposes settings, decided stamps, and automatic downloads")
  func logoutDisposesSettingsDecisionsAndAutomaticDownloads() async throws {
    let env = try await PodcastAutoDownloadJourneyEnvironment()
    try await env.seedShow(itemID: "show-1")
    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "show-1", override: .enabled)
    try await env.seedEpisode(
      itemID: "show-1", episodeID: "ep-1", publishedAt: eligiblePublicationDate())

    let download = try env.makeDownloadHarness()
    let coordinator = env.makeCoordinator(planner: download.coordinator)
    await coordinator.run()
    try await env.finishPendingDownloads(download, itemID: "show-1")
    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") != nil)

    try await env.removeAccount(downloadCoordinator: download.coordinator)

    #expect(try env.accountRowExists() == false)
    // The account-scoped `podcastSettings`/`podcastShowSettings` rows cascade with the account
    // (`podcastSettingsTablesCascadeWithAccount`/`podcastShowSettingsCascadesWithItem`). This
    // proves the whole removal sequence, not just the raw FK, reaches them.
    #expect(try env.showSettingsRowExists(itemID: "show-1") == false)
    #expect(try env.downloadRowExists(itemID: "show-1", episodeID: "ep-1") == false)
  }

  @Test("relaunch preserves settings and never duplicates a decision")
  func relaunchPreservesSettingsAndDuplicatesNothing() async throws {
    let env = try await PodcastAutoDownloadJourneyEnvironment()
    try await env.seedShow(itemID: "show-1")
    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "show-1", override: .enabled)
    try await env.seedEpisode(
      itemID: "show-1", episodeID: "ep-1", publishedAt: eligiblePublicationDate())

    let download = try env.makeDownloadHarness()
    let firstLaunchCoordinator = env.makeCoordinator(planner: download.coordinator)
    await firstLaunchCoordinator.run()
    try await env.finishPendingDownloads(download, itemID: "show-1")
    let decidedBeforeRelaunch = try env.decidedAt(itemID: "show-1", episodeID: "ep-1")
    #expect(decidedBeforeRelaunch != nil)

    // A fresh coordinator and a fresh settings-store read over the same on-disk database is the
    // deterministic "process relaunched" seam (as in `PodcastJourneyTests`).
    var relaunchedSettingsIterator =
      PodcastSettingsStore(database: env.database, accountId: env.accountID)
      .observeShowSettings(itemID: "show-1")
      .makeAsyncIterator()
    let relaunchedSettings = await relaunchedSettingsIterator.next() ?? nil
    #expect(relaunchedSettings?.autoDownloadOverride == .enabled, "settings survive a relaunch")

    let relaunchCoordinator = env.makeCoordinator(planner: download.coordinator)
    await relaunchCoordinator.run()

    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") == decidedBeforeRelaunch, "no re-decision")
    let rows = try await env.database.readAsync { db in
      try DownloadRecord.filter(Column("podcastEpisodeId") != nil).fetchCount(db)
    }
    #expect(rows == 1, "relaunch never duplicates the download row")
  }

  @Test(
    "a crash between creating the download row and stamping decided converges through the repair pass"
  )
  func crashBetweenDownloadRowAndDecidedStampConvergesViaRepair() async throws {
    let env = try await PodcastAutoDownloadJourneyEnvironment()
    try await env.seedShow(itemID: "show-1")
    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "show-1", override: .enabled)
    try await env.seedEpisode(
      itemID: "show-1", episodeID: "ep-1", publishedAt: eligiblePublicationDate())

    // Simulates the process dying after `DownloadCoordinator` committed the row but before
    // `markDecided` landed: the row exists, automatic-origin, with no stamp yet.
    let download = try env.makeDownloadHarness()
    try await download.coordinator.requestAutomaticEpisodeDownload(itemID: "show-1", episodeID: "ep-1")
    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") == nil, "the crash landed before the stamp")

    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let coordinator = env.makeCoordinator(planner: planner)
    await coordinator.run()

    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") != nil, "the repair pass stamps it")
    #expect(await planner.requests.isEmpty, "the surviving row already blocks candidacy - no re-plan")
  }

  @Test("a removal-pending account blocks the auto-download pass entirely")
  func removalPendingAccountBlocksThePass() async throws {
    let env = try await PodcastAutoDownloadJourneyEnvironment()
    try await env.seedShow(itemID: "show-1")
    try await env.settingsStore.setShowAutoDownloadOverride(itemID: "show-1", override: .enabled)
    try await env.seedEpisode(
      itemID: "show-1", episodeID: "ep-1", publishedAt: eligiblePublicationDate())

    try await env.database.writeAsync { db in
      var journal = AccountRemovalJournalRecord(
        serverBaseURL: "https://removal-pending.invalid", serverUserId: "removal-pending-user",
        accountRowId: env.accountID, downloadsRootRelativePath: "Downloads", createdAt: Date())
      try journal.insert(db)
    }

    let planner = FakeAutomaticEpisodeDownloadPlanning()
    let lifecycle = FakeAccountLifecycle()
    lifecycle.isAuthenticated = true
    lifecycle.isRemovalPendingValue = true
    let coordinator = env.makeCoordinator(planner: planner, accountLifecycle: lifecycle)

    await coordinator.run()

    #expect(await planner.requests.isEmpty)
    #expect(try env.decidedAt(itemID: "show-1", episodeID: "ep-1") == nil)
  }
}

// MARK: - Environment

private final class PodcastAutoDownloadJourneyEnvironment: @unchecked Sendable {
  let database: AppDatabase
  let accountID: Int64
  let libraryID: Int64
  let server: ABSServerConfig
  /// Shared across `makeDownloadHarness()` calls and pre-seeded with a token pair.
  /// `DownloadCoordinator.startTransfer` loads tokens through
  /// `client.makeAuthorizedDownloadRequest` before moving a row to `.downloading`, so an empty
  /// token store would strand every download `.pending` (`ABSApi`'s `unauthorized` failure is
  /// swallowed by `try?` at that call site).
  let tokenStore: InMemoryTokenStore
  let tokenAccount: TokenAccount
  private let fixture: SuiteOnDiskDatabases
  private var root: URL { fixture.scope.directoryURL }

  init() async throws {
    let suffix = UUID().uuidString
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "PodcastAutoDownloadJourneyTests")
    self.fixture = fixture
    let localDatabase = try fixture.scope.open(fileAttributes: InertFileAttributes())
    let localServer = try ABSServerConfig(
      url: try #require(URL(string: "https://auto-download-journey-\(suffix).invalid")))
    let serverBaseURLString = localServer.baseURL.absoluteString
    let clientUUID = "auto-download-client-\(suffix)"
    let localTokenAccount = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "auto-download-user")
    let localTokenStore = InMemoryTokenStore()
    try localTokenStore.save(
      TokenPair(accessToken: "access", refreshToken: "refresh"), for: localTokenAccount)

    let ids = try await localDatabase.writeAsync { db -> (Int64, Int64) in
      var account = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: serverBaseURLString,
        serverUserId: "auto-download-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcast-library", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return (account.id!, library.id!)
    }

    database = localDatabase
    server = localServer
    tokenStore = localTokenStore
    tokenAccount = localTokenAccount
    accountID = ids.0
    libraryID = ids.1
  }

  var settingsStore: PodcastSettingsStore {
    PodcastSettingsStore(database: database, accountId: accountID)
  }
  var selectionStore: PodcastAutoDownloadSelectionStore {
    PodcastAutoDownloadSelectionStore(database: database, accountId: accountID)
  }
  var reapStore: PodcastAutoDownloadReapStore {
    PodcastAutoDownloadReapStore(database: database, accountId: accountID)
  }

  @discardableResult
  func seedShow(itemID: String) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: itemID,
        mediaKind: "podcast", title: itemID, sortTitle: itemID)
      try item.insert(db)
      return item.id!
    }
  }

  @discardableResult
  func seedEpisode(
    itemID: String, episodeID: String, publishedAt: Date?, storedAudio: Bool = true
  ) async throws -> Int64 {
    let itemRowID = try #require(
      try ItemDAO(database: database).fetchOne(accountId: accountID, serverItemId: itemID)?.id)
    return try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountID, itemId: itemRowID, serverEpisodeId: episodeID,
        title: "Episode \(episodeID)", durationSeconds: 600, publishedAt: publishedAt,
        storedAudioIno: storedAudio ? "ino-\(episodeID)" : nil,
        storedAudioExpectedSize: storedAudio ? 4_096 : nil,
        storedAudioMimeType: storedAudio ? "audio/mpeg" : nil,
        storedAudioDurationSeconds: storedAudio ? 600 : nil,
        lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
  }

  func decidedAt(itemID: String, episodeID: String) throws -> Date? {
    let itemRowID = try #require(
      try ItemDAO(database: database).fetchOne(accountId: accountID, serverItemId: itemID)?.id)
    return try PodcastEpisodeDAO(database: database).fetchOne(itemId: itemRowID, serverEpisodeId: episodeID)?
      .autoDownloadDecidedAt
  }

  func downloadOrigin(itemID: String, episodeID: String) throws -> DownloadOrigin? {
    let itemRowID = try #require(
      try ItemDAO(database: database).fetchOne(accountId: accountID, serverItemId: itemID)?.id)
    guard
      let episodeRowID = try PodcastEpisodeDAO(database: database).fetchOne(
        itemId: itemRowID, serverEpisodeId: episodeID)?.id
    else { return nil }
    return try DownloadStore(database: database)
      .fetchDownloads(itemId: itemRowID, podcastEpisodeId: episodeRowID)
      .first?.origin
  }

  func downloadRowExists(itemID: String, episodeID: String) throws -> Bool {
    guard let itemRowID = try ItemDAO(database: database).fetchOne(accountId: accountID, serverItemId: itemID)?.id
    else { return false }
    guard
      let episodeRowID = try PodcastEpisodeDAO(database: database).fetchOne(
        itemId: itemRowID, serverEpisodeId: episodeID)?.id
    else { return false }
    return try DownloadStore(database: database)
      .fetchDownloads(itemId: itemRowID, podcastEpisodeId: episodeRowID)
      .isEmpty == false
  }

  func showSettingsRowExists(itemID: String) throws -> Bool {
    try database.read { db in
      try Int64.fetchOne(
        db,
        sql: """
          SELECT podcastShowSettings.accountId FROM podcastShowSettings
          JOIN item ON item.id = podcastShowSettings.itemId
          WHERE item.serverItemId = ?
          """,
        arguments: [itemID]) != nil
    }
  }

  func accountRowExists() throws -> Bool {
    try database.read { db in try AccountRecord.fetchCount(db) > 0 }
  }

  struct DownloadHarness {
    let store: DownloadStore
    let files: DownloadFileStore
    let background: FakeBackgroundTransferring
    let coordinator: DownloadCoordinator
  }

  func makeDownloadHarness() throws -> DownloadHarness {
    let store = try DownloadStore(database: database)
    let files = try DownloadFileStore(
      rootURL: root.appendingPathComponent("Downloads"),
      fileAttributes: InertFileAttributes(), downloadStore: store)
    let background = FakeBackgroundTransferring()
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: tokenStore)
    let coordinator = DownloadCoordinator.make(
      client: client, database: database, downloadStore: store,
      downloadFileStore: files, backgroundTransferring: background,
      downloadPreferences: FakeDownloadPreferences(),
      networkConditions: FakeNetworkConditions(),
      diagnostics: FakeDiagnosticsRecording(),
      freeSpaceReporting: FakeFreeSpaceReporting())
    return DownloadHarness(store: store, files: files, background: background, coordinator: coordinator)
  }

  /// Drives every not-yet-complete download for `itemID` to `.completed`. Like
  /// `PodcastJourneyTestEnvironment.finishAllDownloads` but for one show and polled, so the
  /// adapter's event subscription (a detached `Task` in `DownloadCoordinator.make`) has landed
  /// before the caller inspects state.
  ///
  /// `expectingWork` is the barrier: `coordinator.run()` returning does not mean the planner has
  /// written its row (the plan runs on the coordinator's own executor), so "no rows yet" must not
  /// read as "nothing to do". Pass `false` only where the preceding step plans nothing.
  func finishPendingDownloads(
    _ harness: DownloadHarness, itemID: String, expectingWork: Bool = true
  ) async throws {
    let itemRowID = try #require(
      try ItemDAO(database: database).fetchOne(accountId: accountID, serverItemId: itemID)?.id)

    if expectingWork {
      _ = await TestSupport.awaitCondition(
        "a not-yet-complete download row for \(itemID)",
        observing: {
          let rows = (try? harness.store.fetchDownloads(itemId: itemRowID)) ?? []
          return "states=\(rows.map { String(describing: $0.state) })"
        },
        until: {
          let rows = (try? harness.store.fetchDownloads(itemId: itemRowID)) ?? []
          return rows.contains { $0.state != .completed }
        })
    }

    let pending = try harness.store.fetchDownloads(itemId: itemRowID).filter { $0.state != .completed }
    guard pending.isEmpty == false else { return }
    await TestSupport.waitUntil {
      let rows = (try? harness.store.fetchDownloads(itemId: itemRowID)) ?? []
      return pending.allSatisfy { row in rows.first { $0.id == row.id }?.state == .downloading }
    }
    for row in pending {
      let id = try #require(row.id)
      let temporary = root.appendingPathComponent("transfer-\(id)")
      try Data(repeating: 0x42, count: Int(row.expectedBytes)).write(to: temporary)
      harness.background.pushEvent(
        .finished(
          identity: .abs(rowID: id), temporaryFileURL: temporary,
          response: BackgroundTransferResponse(
            httpStatusCode: 200, mimeType: row.expectedMimeType, contentLength: row.expectedBytes)))
    }
    await TestSupport.waitUntil {
      let rows = (try? harness.store.fetchDownloads(itemId: itemRowID)) ?? []
      return pending.allSatisfy { row in rows.first { $0.id == row.id }?.state == .completed }
    }
  }

  func makeCoordinator(
    planner: any AutomaticEpisodeDownloadPlanning,
    accountLifecycle: any AccountLifecycle = PodcastAutoDownloadJourneyEnvironment.authenticatedLifecycle()
  ) -> PodcastAutoDownloadCoordinator {
    PodcastAutoDownloadCoordinator(
      selecting: selectionStore, planner: planner, accountLifecycle: accountLifecycle,
      networkConditions: FakeNetworkConditions(), podcastSettingsReading: settingsStore,
      accountId: accountID)
  }

  func makeReaper(purging: any PodcastAutoDownloadPurging) -> PodcastAutoDownloadReaper {
    PodcastAutoDownloadReaper(reapCandidateProvider: reapStore, purging: purging, accountId: accountID)
  }

  static func authenticatedLifecycle() -> FakeAccountLifecycle {
    let lifecycle = FakeAccountLifecycle()
    lifecycle.isAuthenticated = true
    return lifecycle
  }

  /// The real production removal sequence (`AccountRemovalCoordinator`) rather than a raw
  /// `DELETE FROM account`, so it proves the sequence reaches the settings tables and downloads,
  /// not only the schema's own `ON DELETE CASCADE`.
  func removeAccount(downloadCoordinator: DownloadCoordinator) async throws {
    let accountDAO = AccountDAO(database: database)
    let journalStore = AccountRemovalJournalStore(database: database)
    let accountRemover = AccountRemover(database: database)
    let coordinator = AccountRemovalCoordinator(
      tokenStore: tokenStore, accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database), journalStore: journalStore,
      accountRemover: accountRemover,
      clientFactory: { server, tokenStore in
        let http = FakeHTTPClient()
        http.enqueue(
          HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)))
        return ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
      },
      downloadCoordinator: downloadCoordinator,
      downloadsRootURL: root.appendingPathComponent("Downloads"))
    try await coordinator.confirmRemoval()
  }
}

// MARK: - Fakes local to this journey

// Stays: it decorates a real `DownloadCoordinator` and forwards to it, which the shared fake
// (a pure recorder) cannot do.
/// Fails the first `failTimes` requests, then forwards to `underlying` (a real
/// `DownloadCoordinator` in these tests). Models both a transient planning error and a mid-pass
/// account removal (the candidate must survive either way, undecided, for a later pass to retry).
private actor FlakyPlanner: AutomaticEpisodeDownloadPlanning {
  private var remainingFailures: Int
  private let underlying: any AutomaticEpisodeDownloadPlanning

  init(failTimes: Int, underlying: any AutomaticEpisodeDownloadPlanning) {
    remainingFailures = failTimes
    self.underlying = underlying
  }

  enum FlakyPlannerError: Error { case transient }

  func requestAutomaticEpisodeDownload(itemID: String, episodeID: String) async throws {
    if remainingFailures > 0 {
      remainingFailures -= 1
      throw FlakyPlannerError.transient
    }
    try await underlying.requestAutomaticEpisodeDownload(itemID: itemID, episodeID: episodeID)
  }
}
