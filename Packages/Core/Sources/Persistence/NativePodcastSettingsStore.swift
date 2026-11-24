import Foundation
import GRDB

public struct NativePodcastSettingsStore: PodcastSettingsReading, PodcastSettingsWriting, Sendable {
  private let database: AppDatabase
  private let now: @Sendable () -> Date
  public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
    self.database = database
    self.now = now
  }
  public func fetchGlobalSettings() async -> PodcastGlobalSettings {
    (try? await database.readAsync { db in
      try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)?.settings ?? .defaults
    }) ?? .defaults
  }
  public func observeGlobalSettings() -> AsyncStream<PodcastGlobalSettings> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)?.settings ?? .defaults
    }
  }
  public func currentShowSettings(itemID: String) -> PodcastShowSettingsDetail? {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return nil }
    return try? database.read { db in try PodcastSettingsStore.nativeRSSShowDetail(db, feedId: feedID) }
  }
  public func observeShowSettings(itemID: String) -> AsyncStream<PodcastShowSettingsDetail?> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return nil }
      return try PodcastSettingsStore.nativeRSSShowDetail(db, feedId: feedID)
    }
  }
  public func observeShowSummaries() -> AsyncStream<[PodcastShowSettingsSummary]> {
    ObservationBridge.stream(in: database.dbWriter) { db in try PodcastSettingsStore.nativeShowSummaries(db) }
  }
  public func setGlobalAutoDownloadEnabled(_ enabled: Bool) async throws {
    try await update { record in
      if !record.autoDownloadEnabled && enabled { record.enabledAt = self.now() }
      record.autoDownloadEnabled = enabled
    }
  }
  public func setGlobalKeepLatestCount(_ count: Int) async throws {
    guard count >= 0 else { throw PodcastSettingsStoreError.invalidKeepLatest(count) }
    try await update { $0.keepLatestCount = count }
  }
  public func setGlobalDeleteAfterPlayed(_ enabled: Bool) async throws {
    try await update { $0.deleteAfterPlayed = enabled }
  }
  public func setGlobalAllowCellularAutoDownload(_ enabled: Bool) async throws {
    try await update { $0.allowCellularAutoDownload = enabled }
  }
  public func setShowAutoDownloadOverride(itemID: String, override: PodcastShowAutoDownloadOverride) async throws {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      throw PodcastSettingsStoreError.itemNotFound
    }
    try await RSSFeedSettingsStore(database: database).setAutoDownloadOverride(feedId: feedID, override: override)
  }
  public func setShowKeepLatestOverride(itemID: String, count: Int?) async throws {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      throw PodcastSettingsStoreError.itemNotFound
    }
    try await RSSFeedSettingsStore(database: database).setKeepLatestOverride(feedId: feedID, count: count)
  }
  public func setShowDeleteAfterPlayedOverride(itemID: String, enabled: Bool?) async throws {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      throw PodcastSettingsStoreError.itemNotFound
    }
    try await RSSFeedSettingsStore(database: database).setDeleteAfterPlayedOverride(feedId: feedID, enabled: enabled)
  }
  public func setShowIncludeInLatest(itemID: String, enabled: Bool) async throws {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      throw PodcastSettingsStoreError.itemNotFound
    }
    try await RSSFeedSettingsStore(database: database).setIncludeInLatest(feedId: feedID, enabled: enabled)
  }
  public func setShowNotificationOverride(itemID: String, override: RSSNotificationOverride) async throws {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      throw PodcastSettingsStoreError.itemNotFound
    }
    try await RSSFeedSettingsStore(database: database).setNotificationOverride(feedId: feedID, override: override)
  }
  private func update(_ body: @Sendable (inout NativePodcastSettingsRecord) -> Void) async throws {
    try await database.writeAsync { db in
      var record =
        try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)
        ?? NativePodcastSettingsRecord()
      body(&record)
      try record.save(db)
    }
  }
}
