import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct RSSFeedSettingsStoreTests {
  @Test func includeInLatestUpdatesWithoutChangingOtherFeedSettings() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await subscribeFeed(in: database, name: "latest")
    let store = RSSFeedSettingsStore(database: database)
    try await store.setRateOverride(feedId: feedID, rateStep: 36)

    try await store.setIncludeInLatest(feedId: feedID, enabled: false)

    let settings = try await store.settings(feedId: feedID)
    #expect(settings?.includeInLatest == false)
    #expect(settings?.rateStep == 36)
  }

  @Test func notificationOverrideDefaultsToInheritAndDoesNotChangeLatestMembership() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await subscribeFeed(in: database, name: "notifications")
    let store = RSSFeedSettingsStore(database: database)

    #expect(try await store.notificationOverride(feedId: feedID) == .inherit)
    try await store.setIncludeInLatest(feedId: feedID, enabled: false)
    try await store.setNotificationOverride(feedId: feedID, override: .enabled)

    #expect(try await store.notificationOverride(feedId: feedID) == .enabled)
    #expect(try await store.settings(feedId: feedID)?.includeInLatest == false)
  }

  @Test func absentRowUsesInheritDefaultsAndGlobalValues() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribeFeed(in: database, name: "absent")
    let store = RSSFeedSettingsStore(database: database)

    #expect(try await store.settings(feedId: feedId) == nil)
    let defaults = try await store.effectiveSettings(feedId: feedId, global: .defaults)
    #expect(defaults.effective.isEnabled == false)
    #expect(defaults.effective.keepLatestCount == 3)
    #expect(defaults.effective.deleteAfterPlayed == false)
    #expect(defaults.rateStep == nil)
    #expect(defaults.includeInLatest == true)

    let global = PodcastGlobalSettings(
      autoDownloadEnabled: true, keepLatestCount: 5, deleteAfterPlayed: true,
      allowCellularAutoDownload: false, enabledAt: nil)
    let effective = try await store.effectiveSettings(feedId: feedId, global: global)
    #expect(effective.effective.isEnabled)
    #expect(effective.effective.keepLatestCount == 5)
    #expect(effective.effective.deleteAfterPlayed)
  }

  @Test func unknownFeedIsNotFoundForEveryAPI() async throws {
    let store = RSSFeedSettingsStore(database: try AppDatabase.inMemory())
    await #expect(throws: RSSFeedSettingsStoreError.feedNotFound) {
      try await store.settings(feedId: 999)
    }
    await #expect(throws: RSSFeedSettingsStoreError.feedNotFound) {
      try await store.updateSettings(
        feedId: 999, autoDownload: .inherit, keepLatest: nil, deleteAfterPlayed: nil,
        rateStep: nil, includeInLatest: true)
    }
    await #expect(throws: RSSFeedSettingsStoreError.feedNotFound) {
      try await store.effectiveSettings(feedId: 999, global: .defaults)
    }
    #expect(try await store.effectiveSettingsForAllFeeds(global: .defaults).isEmpty)
  }

  @Test func updateRoundTripsAndReplacesTheSingleRow() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribeFeed(in: database, name: "round-trip")
    let store = RSSFeedSettingsStore(database: database)
    try await store.updateSettings(
      feedId: feedId, autoDownload: .enabled, keepLatest: 0, deleteAfterPlayed: true,
      rateStep: 20, includeInLatest: false)
    let first = try #require(try await store.settings(feedId: feedId))
    #expect(
      first
        == RSSFeedSettingsRecord(
          feedId: feedId, autoDownload: "enabled", keepLatest: 0, deleteAfterPlayed: true,
          rateStep: 20, includeInLatest: false))

    try await store.updateSettings(
      feedId: feedId, autoDownload: .disabled, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: 30, includeInLatest: true)
    let second = try #require(try await store.settings(feedId: feedId))
    #expect(second.autoDownload == "disabled")
    #expect(second.keepLatest == nil)
    #expect(second.deleteAfterPlayed == nil)
    #expect(second.rateStep == 30)
    #expect(try await store.effectiveSettingsForAllFeeds(global: .defaults).count == 1)
    let count = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssFeedSettings WHERE feedId = ?", arguments: [feedId])
    }
    #expect(count == 1)
  }

  @Test func invalidRetentionAndRateWritesLeaveTheExistingSettingsUntouched() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribeFeed(in: database, name: "bounded-writes")
    let store = RSSFeedSettingsStore(database: database)
    try await store.updateSettings(
      feedId: feedId, autoDownload: .enabled, keepLatest: 3, deleteAfterPlayed: true,
      rateStep: 20, includeInLatest: false)
    let existing = try #require(try await store.settings(feedId: feedId))

    await #expect(throws: RSSFeedSettingsStoreError.invalidKeepLatest(-1)) {
      try await store.updateSettings(
        feedId: feedId, autoDownload: .disabled, keepLatest: -1, deleteAfterPlayed: false,
        rateStep: 30, includeInLatest: true)
    }
    #expect(try await store.settings(feedId: feedId) == existing)

    await #expect(throws: RSSFeedSettingsStoreError.invalidKeepLatest(-2)) {
      try await store.setKeepLatestOverride(feedId: feedId, count: -2)
    }
    #expect(try await store.settings(feedId: feedId) == existing)

    for rateStep in [
      ItemPlaybackSettingsRateBounds.minimumStep - 1,
      ItemPlaybackSettingsRateBounds.maximumStep + 1,
    ] {
      await #expect(throws: RSSFeedSettingsStoreError.invalidRateStep(rateStep)) {
        try await store.updateSettings(
          feedId: feedId, autoDownload: .disabled, keepLatest: 10,
          deleteAfterPlayed: false, rateStep: rateStep, includeInLatest: true)
      }
      #expect(try await store.settings(feedId: feedId) == existing)
    }
  }

  @Test func resolverTriStateAndOptionalOverridesArePreserved() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribeFeed(in: database, name: "tri-state")
    let store = RSSFeedSettingsStore(database: database)
    let on = PodcastGlobalSettings(
      autoDownloadEnabled: true, keepLatestCount: 7, deleteAfterPlayed: true,
      allowCellularAutoDownload: false, enabledAt: nil)
    let off = PodcastGlobalSettings(
      autoDownloadEnabled: false, keepLatestCount: 7, deleteAfterPlayed: false,
      allowCellularAutoDownload: false, enabledAt: nil)

    try await store.updateSettings(
      feedId: feedId, autoDownload: .enabled, keepLatest: 0, deleteAfterPlayed: false,
      rateStep: nil, includeInLatest: true)
    var effective = try await store.effectiveSettings(feedId: feedId, global: off)
    #expect(effective.effective.isEnabled && effective.effective.keepLatestCount == 0)
    #expect(!effective.effective.deleteAfterPlayed)

    try await store.updateSettings(
      feedId: feedId, autoDownload: .disabled, keepLatest: nil, deleteAfterPlayed: true,
      rateStep: nil, includeInLatest: true)
    effective = try await store.effectiveSettings(feedId: feedId, global: on)
    #expect(!effective.effective.isEnabled && effective.effective.keepLatestCount == 7)
    #expect(effective.effective.deleteAfterPlayed)

    try await store.updateSettings(
      feedId: feedId, autoDownload: .inherit, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: nil, includeInLatest: true)
    effective = try await store.effectiveSettings(feedId: feedId, global: on)
    #expect(effective.effective.isEnabled)
    #expect(effective.effective.keepLatestCount == 7)
    #expect(effective.effective.deleteAfterPlayed)
  }

  @Test func parseFailsClosedForUnknownRawValues() {
    // The CHECK constraint prevents staging stored garbage for a round-trip test.
    #expect(PodcastShowAutoDownloadOverride.parse("garbage") == .disabled)
  }

  @Test func resolvesAllFeedsIncludingRowlessFeedsAndOnlyCurrentDatabaseFeeds() async throws {
    let database = try AppDatabase.inMemory()
    let otherDatabase = try AppDatabase.inMemory()
    let first = try await subscribeFeed(in: database, name: "enabled")
    let second = try await subscribeFeed(in: database, name: "disabled")
    _ = try await subscribeFeed(in: database, name: "rowless")
    _ = try await subscribeFeed(in: otherDatabase, name: "other")
    let store = RSSFeedSettingsStore(database: database)
    try await store.updateSettings(
      feedId: first, autoDownload: .enabled, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: nil, includeInLatest: true)
    try await store.updateSettings(
      feedId: second, autoDownload: .disabled, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: nil, includeInLatest: true)

    let values = try await store.effectiveSettingsForAllFeeds(global: .defaults)
    #expect(values.count == 3)
    #expect(values[first]?.effective.isEnabled == true)
    #expect(values[second]?.effective.isEnabled == false)
    #expect(values.values.filter { $0.effective.isEnabled }.count == 1)
  }

  @Test func unsubscribeCascadesSettingsRow() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribeFeed(in: database, name: "cascade")
    let store = RSSFeedSettingsStore(database: database)
    try await store.updateSettings(
      feedId: feedId, autoDownload: .enabled, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: nil, includeInLatest: true)
    try await RSSFeedStore(database: database).unsubscribe(feedId: feedId)
    let count = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssFeedSettings WHERE feedId = ?", arguments: [feedId])
    }
    #expect(count == 0)
  }

  @Test func rssOnlyValuesPassThroughGlobalVariations() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribeFeed(in: database, name: "rss-only")
    let store = RSSFeedSettingsStore(database: database)
    try await store.updateSettings(
      feedId: feedId, autoDownload: .inherit, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: 30, includeInLatest: false)
    let off = try await store.effectiveSettings(feedId: feedId, global: .defaults)
    let on = try await store.effectiveSettings(
      feedId: feedId,
      global: PodcastGlobalSettings(
        autoDownloadEnabled: true, keepLatestCount: 1, deleteAfterPlayed: true,
        allowCellularAutoDownload: true, enabledAt: Date()))
    #expect(off.rateStep == 30 && !off.includeInLatest)
    #expect(on.rateStep == 30 && !on.includeInLatest)
  }

  @Test func rateOverrideRoundTripsAndClearPreservesOtherSettings() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribeFeed(in: database, name: "rate")
    let store = RSSFeedSettingsStore(database: database)
    try await store.setAutoDownloadOverride(feedId: feedId, override: .enabled)

    try await store.setRateOverride(feedId: feedId, rateStep: 36)
    #expect(try await store.fetchRateOverride(feedId: feedId) == 36)
    #expect(try await store.fetchRateOverrides() == [feedId: 36])

    try await store.clearRateOverride(feedId: feedId)
    #expect(try await store.fetchRateOverride(feedId: feedId) == nil)
    #expect(try await store.settings(feedId: feedId)?.autoDownload == "enabled")
  }

  @Test func clearAllRateOverridesLeavesDeviceOwnedRowsAndOnlyClearsRates() async throws {
    let database = try AppDatabase.inMemory()
    let first = try await subscribeFeed(in: database, name: "rate-first")
    let second = try await subscribeFeed(in: database, name: "rate-second")
    let store = RSSFeedSettingsStore(database: database)
    try await store.updateSettings(
      feedId: first, autoDownload: .enabled, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: 22, includeInLatest: true)
    try await store.updateSettings(
      feedId: second, autoDownload: .disabled, keepLatest: 4, deleteAfterPlayed: true,
      rateStep: 44, includeInLatest: false)

    try await store.clearAllRateOverrides()

    #expect(try await store.fetchRateOverrides().isEmpty)
    #expect(try await store.settings(feedId: first)?.autoDownload == "enabled")
    #expect(try await store.settings(feedId: second)?.keepLatest == 4)
    #expect(try await store.settings(feedId: second)?.includeInLatest == false)
  }

  private func subscribeFeed(in database: AppDatabase, name: String) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(name).xml")!, title: name, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }
}
