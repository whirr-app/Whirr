import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct PodcastSettingsStoreTests {

  // MARK: - Global settings

  @Test func absentGlobalRowMeansDefaults() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    let settings = await store.fetchGlobalSettings()

    #expect(settings == .defaults)
    #expect(settings.autoDownloadEnabled == false)
    #expect(settings.keepLatestCount == 3)
    #expect(settings.deleteAfterPlayed == false)
    #expect(settings.allowCellularAutoDownload == false)
    #expect(settings.enabledAt == nil)
  }

  @Test func settingGlobalOnStampsEnabledAt() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let stampedAt = Date(timeIntervalSince1970: 1_000)
    let store = PodcastSettingsStore(
      database: database, accountId: fixture.accountId, now: { stampedAt })

    try await store.setGlobalAutoDownloadEnabled(true)

    let settings = await store.fetchGlobalSettings()
    #expect(settings.autoDownloadEnabled == true)
    #expect(settings.enabledAt == stampedAt)
  }

  @Test func settingGlobalOffKeepsStamp() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let stampedAt = Date(timeIntervalSince1970: 1_000)
    let store = PodcastSettingsStore(
      database: database, accountId: fixture.accountId, now: { stampedAt })

    try await store.setGlobalAutoDownloadEnabled(true)
    try await store.setGlobalAutoDownloadEnabled(false)

    let settings = await store.fetchGlobalSettings()
    #expect(settings.autoDownloadEnabled == false)
    #expect(settings.enabledAt == stampedAt)
  }

  @Test func reEnablingGlobalStampsAFreshEnabledAt() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let store = PodcastSettingsStore(
      database: database, accountId: fixture.accountId, now: { clock.now })

    try await store.setGlobalAutoDownloadEnabled(true)
    let firstStamp = await store.fetchGlobalSettings().enabledAt
    try await store.setGlobalAutoDownloadEnabled(false)
    clock.advance(by: 1_000)
    try await store.setGlobalAutoDownloadEnabled(true)
    let secondStamp = await store.fetchGlobalSettings().enabledAt

    #expect(firstStamp == Date(timeIntervalSince1970: 1_000))
    #expect(secondStamp == Date(timeIntervalSince1970: 2_000))
  }

  // MARK: - Show defaults and simple overrides

  @Test func showDefaultsToInherit() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    let detail = try await store.fetchShowSettings(itemID: fixture.serverItemID)

    #expect(detail.autoDownloadOverride == .inherit)
    #expect(detail.keepLatestOverride == nil)
    #expect(detail.deleteAfterPlayedOverride == nil)
    #expect(detail.effective.isEnabled == false)
    #expect(detail.effective.keepLatestCount == 3)
    #expect(detail.effective.deleteAfterPlayed == false)
  }

  @Test func showOverrideOnStampsShowFloor() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let stampedAt = Date(timeIntervalSince1970: 1_000)
    let store = PodcastSettingsStore(
      database: database, accountId: fixture.accountId, now: { stampedAt })

    // Global stays off; the show's own override flips it effectively off -> on.
    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .enabled)

    let detail = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(detail.effective.isEnabled == true)
    #expect(detail.enabledAt == stampedAt)
    #expect(detail.effective.floor == stampedAt)
  }

  @Test func showOverrideOffDisablesAgainstGlobalOn() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(
      database: database, accountId: fixture.accountId,
      now: { Date(timeIntervalSince1970: 1_000) })
    try await store.setGlobalAutoDownloadEnabled(true)

    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .disabled)

    let detail = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(detail.autoDownloadOverride == .disabled)
    #expect(detail.effective.isEnabled == false)
  }

  // MARK: - RSS feed settings projection

  @Test func followedFeedAppearsWithInheritedGlobalResolvedValues() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)
    let native = NativePodcastSettingsStore(database: database)
    try await native.setGlobalAutoDownloadEnabled(true)
    try await native.setGlobalKeepLatestCount(7)
    try await native.setGlobalDeleteAfterPlayed(true)
    let feedID = try await Self.subscribeFeed(database, title: "RSS Feed")

    let summary = try #require(await store.fetchShowSummaries().last)
    let expectedItemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
    #expect(summary.itemID == expectedItemID)
    #expect(summary.title == "RSS Feed")
    #expect(summary.autoDownloadOverride == .inherit)
    #expect(summary.effective.isEnabled)
    #expect(summary.effective.keepLatestCount == 7)
    #expect(summary.effective.deleteAfterPlayed)
  }

  @Test func feedOverridesRoundTripWithoutTouchingRSSOnlyColumns() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let feedID = try await Self.subscribeFeed(database, title: "Writable Feed")
    let settings = RSSFeedSettingsStore(database: database)
    try await settings.updateSettings(
      feedId: feedID, autoDownload: .inherit, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: 20, includeInLatest: false)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId

    try await store.setShowAutoDownloadOverride(itemID: itemID, override: .enabled)
    try await store.setShowKeepLatestOverride(itemID: itemID, count: 9)
    try await store.setShowDeleteAfterPlayedOverride(itemID: itemID, enabled: true)
    try await store.setShowNotificationOverride(itemID: itemID, override: .enabled)

    let row = try #require(try await settings.settings(feedId: feedID))
    #expect(row.autoDownload == "enabled")
    #expect(row.keepLatest == 9)
    #expect(row.deleteAfterPlayed == true)
    #expect(row.rateStep == 20)
    #expect(row.includeInLatest == false)
    #expect(row.notificationOverride == RSSNotificationOverride.enabled.rawValue)
    let detail = try await store.fetchShowSettings(itemID: itemID)
    #expect(detail.includeInLatest == false)
    #expect(detail.notificationOverride == .enabled)
  }

  @Test func showSummaryObservationTracksRSSFeedAndSettingsTables() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)
    var iterator = store.observeShowSummaries().makeAsyncIterator()
    _ = try #require(await iterator.next())

    let feedID = try await Self.subscribeFeed(database, title: "Observed Feed")
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
    #expect((try #require(await iterator.next())).contains { $0.itemID == itemID })

    try await RSSFeedSettingsStore(database: database).setAutoDownloadOverride(
      feedId: feedID, override: .enabled)
    let afterSettings = try #require(await iterator.next())
    #expect(afterSettings.first { $0.itemID == itemID }?.autoDownloadOverride == .enabled)
  }

  @Test func malformedAndUnknownRSSShowsNeverFallBackToABS() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    for itemID in ["rss:0", "RSS:1", "rss:abc", "rss:999"] {
      await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
        _ = try await store.fetchShowSettings(itemID: itemID)
      }
      #expect(store.currentShowSettings(itemID: itemID) == nil)
      await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
        try await store.setShowAutoDownloadOverride(itemID: itemID, override: .enabled)
      }
    }
  }

  // MARK: - The preference-race guard

  @Test func offToInheritWhileGlobalOnStampsFreshShowFloor() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId, now: { clock.now })

    try await store.setGlobalAutoDownloadEnabled(true)  // global floor stamped at t=1000
    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .disabled)
    clock.advance(by: 5_000)  // the show sits Off for a while
    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .inherit)

    let detail = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(detail.effective.isEnabled == true)
    // A fresh floor at the moment of re-inheriting, never the stale global stamp from t=1000.
    // Otherwise episodes published during the Off interval would be backfilled.
    #expect(detail.effective.floor == Date(timeIntervalSince1970: 6_000))
  }

  // MARK: - Explicit-override floor preservation

  @Test func inheritToExplicitOnPreservesTheEffectiveFloor() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let globalOnAt = Date(timeIntervalSince1970: 1_000)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId, now: { globalOnAt })
    try await store.setGlobalAutoDownloadEnabled(true)

    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .enabled)

    let detail = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(detail.effective.isEnabled == true)
    #expect(detail.effective.floor == globalOnAt)
    #expect(detail.enabledAt == globalOnAt)
  }

  @Test func explicitOnIsUnaffectedByLaterGlobalChanges() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId, now: { clock.now })

    try await store.setGlobalAutoDownloadEnabled(true)  // global floor: t=1000
    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .enabled)
    let floorAfterAdopting = try await store.fetchShowSettings(itemID: fixture.serverItemID).effective.floor

    clock.advance(by: 5_000)
    try await store.setGlobalAutoDownloadEnabled(false)
    clock.advance(by: 5_000)
    try await store.setGlobalAutoDownloadEnabled(true)  // a brand new global floor: t=11000

    let detail = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(floorAfterAdopting == Date(timeIntervalSince1970: 1_000))
    #expect(detail.effective.floor == floorAfterAdopting)
    #expect(detail.effective.floor != Date(timeIntervalSince1970: 11_000))
  }

  @Test func unchangedEffectiveOnDoesNotMoveTheFloor() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let clock = TestClock(Date(timeIntervalSince1970: 1_000))
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId, now: { clock.now })

    try await store.setGlobalAutoDownloadEnabled(true)
    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .enabled)
    let floorAfterAdopting = try await store.fetchShowSettings(itemID: fixture.serverItemID).effective.floor

    clock.advance(by: 5_000)
    // `enabled` -> `inherit` while global stays on: continuously effectively on, no gap, so no
    // fresh stamp.
    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .inherit)
    let afterInherit = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(afterInherit.effective.isEnabled == true)
    #expect(afterInherit.enabledAt == floorAfterAdopting)

    clock.advance(by: 5_000)
    // A genuine no-op transition also must not move anything.
    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .inherit)
    let afterNoOp = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(afterNoOp.enabledAt == floorAfterAdopting)
  }

  // MARK: - Independent field inheritance

  @Test func keepLatestAndDeleteAfterPlayedResolveThroughInheritance() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)
    try await store.setGlobalKeepLatestCount(5)
    try await store.setGlobalDeleteAfterPlayed(true)

    let inherited = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(inherited.effective.keepLatestCount == 5)
    #expect(inherited.effective.deleteAfterPlayed == true)

    try await store.setShowKeepLatestOverride(itemID: fixture.serverItemID, count: 10)
    let afterKeepLatestOverride = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(afterKeepLatestOverride.effective.keepLatestCount == 10)
    #expect(afterKeepLatestOverride.effective.deleteAfterPlayed == true)  // still inherited

    try await store.setShowDeleteAfterPlayedOverride(itemID: fixture.serverItemID, enabled: false)
    let afterBothOverrides = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(afterBothOverrides.effective.keepLatestCount == 10)
    #expect(afterBothOverrides.effective.deleteAfterPlayed == false)
  }

  @Test func zeroKeepLatestMeansAll() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    try await store.setShowKeepLatestOverride(itemID: fixture.serverItemID, count: 0)

    let detail = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(detail.keepLatestOverride == 0)
    #expect(detail.effective.keepLatestCount == 0)  // distinct from `nil` (inherit -> 3)
  }

  // MARK: - Scoping and validation

  @Test func settingsAreAccountScoped() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await Self.seed(database, suffix: "first")
    let second = try await Self.seed(database, suffix: "second")
    let firstStore = PodcastSettingsStore(database: database, accountId: first.accountId)
    let secondStore = PodcastSettingsStore(database: database, accountId: second.accountId)

    try await firstStore.setGlobalAutoDownloadEnabled(true)
    try await firstStore.setShowAutoDownloadOverride(itemID: first.serverItemID, override: .enabled)

    let secondGlobal = await secondStore.fetchGlobalSettings()
    #expect(secondGlobal.autoDownloadEnabled == false)
    let secondShow = try await secondStore.fetchShowSettings(itemID: second.serverItemID)
    #expect(secondShow.autoDownloadOverride == .inherit)
    #expect(secondShow.effective.isEnabled == false)

    let firstGlobal = await firstStore.fetchGlobalSettings()
    #expect(firstGlobal.autoDownloadEnabled == true)
  }

  @Test func unknownItemCannotReceiveShowSettings() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let softDeletedItemId = try await Self.addShow(
      database, accountId: fixture.accountId, libraryId: fixture.libraryId, suffix: "gone",
      softDeleted: true)
    _ = softDeletedItemId
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
      try await store.setShowAutoDownloadOverride(itemID: "does-not-exist", override: .enabled)
    }
    await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
      try await store.setShowAutoDownloadOverride(itemID: "show-gone", override: .enabled)
    }
    await #expect(throws: PodcastSettingsStoreError.itemNotFound) {
      _ = try await store.fetchShowSettings(itemID: "does-not-exist")
    }
  }

  @Test func unknownStoredOverrideFailsClosedToDisabled() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(
      database: database, accountId: fixture.accountId,
      now: { Date(timeIntervalSince1970: 1_000) })
    try await store.setGlobalAutoDownloadEnabled(true)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO podcastShowSettings
            (itemId, accountId, autoDownloadOverride, keepLatestOverride, deleteAfterPlayedOverride, enabledAt)
          VALUES (?, ?, 'bogus', NULL, NULL, NULL)
          """,
        arguments: [fixture.itemId, fixture.accountId])
    }

    let detail = try await store.fetchShowSettings(itemID: fixture.serverItemID)
    #expect(detail.autoDownloadOverride == .disabled)
    #expect(detail.effective.isEnabled == false)  // fails closed even though global is on

    // The show is not hidden. It still surfaces in the ordered list, resolved to disabled.
    let summaries = await store.fetchShowSummaries()
    #expect(summaries.map(\.itemID) == [fixture.serverItemID])
    #expect(summaries.first?.autoDownloadOverride == .disabled)
  }

  // MARK: - Observation

  @Test func showSummaryObservationUpdatesAfterMutation() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    var iterator = store.observeShowSummaries().makeAsyncIterator()
    let initial = try #require(await iterator.next())
    #expect(initial.map(\.autoDownloadOverride) == [.inherit])

    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .enabled)

    let updated = try #require(await iterator.next())
    #expect(updated.map(\.autoDownloadOverride) == [.enabled])
  }

  @Test func showSettingsObservationReflectsMutationsForOneShow() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    var iterator = store.observeShowSettings(itemID: fixture.serverItemID).makeAsyncIterator()
    let initial = try #require(await iterator.next())
    #expect(initial?.autoDownloadOverride == .inherit)

    try await store.setShowAutoDownloadOverride(itemID: fixture.serverItemID, override: .enabled)

    let updated = try #require(await iterator.next())
    #expect(updated?.autoDownloadOverride == .enabled)
  }

  @Test func softDeletedShowsAreAbsentFromSettingsList() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    _ = try await Self.addShow(
      database, accountId: fixture.accountId, libraryId: fixture.libraryId, suffix: "hidden",
      softDeleted: true)
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    let summaries = await store.fetchShowSummaries()

    #expect(summaries.map(\.itemID) == [fixture.serverItemID])
  }

  @Test func optedOutShowsAreAbsentFromSettingsSummaries() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let excludedLibraryID = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: fixture.accountId, serverLibraryId: "excluded", mediaType: "podcast",
        name: "Excluded", isIncluded: false)
      try library.insert(db)
      return library.id!
    }
    _ = try await Self.addShow(
      database, accountId: fixture.accountId, libraryId: excludedLibraryID, suffix: "excluded")
    let store = PodcastSettingsStore(database: database, accountId: fixture.accountId)

    #expect(await store.fetchShowSummaries().map(\.itemID) == [fixture.serverItemID])
  }

  // MARK: - Fixtures

  private struct Fixture {
    let accountId: Int64
    let libraryId: Int64
    let itemId: Int64
    let serverItemID: String
  }

  private static func seed(
    _ database: AppDatabase,
    suffix: String = "primary",
    title: String = "Show"
  ) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(suffix)", serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-\(suffix)", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      let serverItemID = "show-\(suffix)"
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: serverItemID,
        mediaKind: "podcast", title: title, sortTitle: title.lowercased())
      try item.insert(db)
      return Fixture(
        accountId: account.id!, libraryId: library.id!, itemId: item.id!,
        serverItemID: serverItemID)
    }
  }

  private static func addShow(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    suffix: String,
    softDeleted: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "show-\(suffix)",
        mediaKind: "podcast", title: "Show \(suffix)", sortTitle: "show \(suffix)",
        softDeleted: softDeleted)
      try item.insert(db)
      return item.id!
    }
  }

  private static func subscribeFeed(_ database: AppDatabase, title: String) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(
        string: "https://example.com/\(title.lowercased().replacingOccurrences(of: " ", with: "-")).xml"
      )!,
      title: title, author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }
}
