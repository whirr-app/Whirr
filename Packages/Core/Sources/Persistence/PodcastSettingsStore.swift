import Foundation
import GRDB

public enum PodcastSettingsStoreError: Error, Equatable, Sendable {
  case itemNotFound
  case invalidKeepLatest(Int)
}

/// Persistence for the device-side podcast auto-download settings: the account's global defaults,
/// each show's tri-state override, and the activation-floor stamping that both mutate
/// transactionally. `PodcastEffectiveSettingsResolver` (`PodcastSettingsValues.swift`) is the only
/// place resolution logic lives; the selection and reap stores call it directly.
///
/// A thin, stateless wrapper around `AppDatabase`, like `ListeningQueueStore`, exposing no GRDB
/// types.
public struct PodcastSettingsStore: Sendable {
  private let database: AppDatabase
  private let accountId: Int64
  private let now: @Sendable () -> Date

  public init(
    database: AppDatabase,
    accountId: Int64,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.accountId = accountId
    self.now = now
  }

  // MARK: - Global settings

  public func fetchGlobalSettings() async -> PodcastGlobalSettings {
    (try? await database.readAsync { db in
      try Self.globalSettings(db, accountId: self.accountId)
    }) ?? .defaults
  }

  public func observeGlobalSettings() -> AsyncStream<PodcastGlobalSettings> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.globalSettings(db, accountId: self.accountId)
    }
  }

  /// Off -> On stamps a fresh `enabledAt`; On -> Off keeps the existing stamp (inactive while off,
  /// not cleared) so a later re-enable can be told apart from the first one.
  public func setGlobalAutoDownloadEnabled(_ enabled: Bool) async throws {
    try await updateGlobal { record in
      let wasEnabled = record.autoDownloadEnabled
      record.autoDownloadEnabled = enabled
      if !wasEnabled && enabled {
        record.enabledAt = self.now()
      }
    }
  }

  public func setGlobalKeepLatestCount(_ count: Int) async throws {
    try await updateGlobal { record in
      record.keepLatestCount = count
    }
  }

  public func setGlobalDeleteAfterPlayed(_ enabled: Bool) async throws {
    try await updateGlobal { record in
      record.deleteAfterPlayed = enabled
    }
  }

  public func setGlobalAllowCellularAutoDownload(_ enabled: Bool) async throws {
    try await updateGlobal { record in
      record.allowCellularAutoDownload = enabled
    }
  }

  // MARK: - Show settings

  public func fetchShowSettings(itemID: String) async throws -> PodcastShowSettingsDetail {
    try await database.readAsync { db in
      guard let detail = try Self.settingsDetail(db, accountId: self.accountId, itemID: itemID)
      else { throw PodcastSettingsStoreError.itemNotFound }
      return detail
    }
  }

  public func currentShowSettings(itemID: String) -> PodcastShowSettingsDetail? {
    try? database.read { db in
      try Self.settingsDetail(db, accountId: self.accountId, itemID: itemID)
    }
  }

  /// Yields `nil` rather than throwing: this is an observation, and a show that disappears (or has
  /// not synced yet) is a value, not a failure.
  public func observeShowSettings(itemID: String) -> AsyncStream<PodcastShowSettingsDetail?> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.settingsDetail(db, accountId: self.accountId, itemID: itemID)
    }
  }

  public func fetchShowSummaries() async -> [PodcastShowSettingsSummary] {
    (try? await database.readAsync { db in
      try Self.showSummaries(db, accountId: self.accountId)
    }) ?? []
  }

  public func observeShowSummaries() -> AsyncStream<[PodcastShowSettingsSummary]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.showSummaries(db, accountId: self.accountId)
    }
  }

  /// The only mutation that stamps `podcastShowSettings.enabledAt`. Every other transition (a
  /// no-op, `enabled` -> `inherit` while global stays on, or one that stays effectively off)
  /// carries the existing stamp forward untouched.
  public func setShowAutoDownloadOverride(
    itemID: String,
    override: PodcastShowAutoDownloadOverride
  ) async throws {
    if let feedId = try Self.rssFeedID(for: itemID) {
      try await onRSSFeed { try await $0.setAutoDownloadOverride(feedId: feedId, override: override) }
      return
    }

    try await database.writeAsync { db in
      let itemRowId = try Self.requireLiveItemRowId(db, accountId: self.accountId, itemID: itemID)
      let global = try Self.globalSettings(db, accountId: self.accountId)
      let row = try Self.showRow(db, accountId: self.accountId, itemRowId: itemRowId)
      let previousOverride = PodcastShowAutoDownloadOverride.parse(row.autoDownloadOverrideRaw)
      let previousEffective = PodcastEffectiveSettingsResolver.resolve(
        global: global,
        showOverride: previousOverride,
        showKeepLatestOverride: row.keepLatestOverride,
        showDeleteAfterPlayedOverride: row.deleteAfterPlayedOverride,
        showEnabledAt: row.enabledAt)

      let enabledAt: Date?
      if !previousEffective.isEnabled && override == .enabled {
        // Effective Off -> On: an explicit override switched on while previously off.
        enabledAt = self.now()
      } else if previousOverride == .disabled && override == .inherit
        && global.autoDownloadEnabled
      {
        // Effective Off -> On: `disabled` -> `inherit` while global is on. The preference-race
        // guard needs a fresh floor here, never the stale global one.
        enabledAt = self.now()
      } else if previousOverride == .inherit && override == .enabled
        && previousEffective.isEnabled
      {
        // Already effectively on: adopt an explicit override without opening a gap. Copy
        // the current effective floor so a later global change cannot move it.
        enabledAt = previousEffective.floor
      } else {
        enabledAt = row.enabledAt
      }

      try Self.saveShowSettings(
        db,
        accountId: self.accountId,
        itemRowId: itemRowId,
        autoDownloadOverride: override,
        keepLatestOverride: row.keepLatestOverride,
        deleteAfterPlayedOverride: row.deleteAfterPlayedOverride,
        enabledAt: enabledAt)
    }
  }

  public func setShowKeepLatestOverride(itemID: String, count: Int?) async throws {
    if let feedId = try Self.rssFeedID(for: itemID) {
      try await onRSSFeed { try await $0.setKeepLatestOverride(feedId: feedId, count: count) }
      return
    }

    try await database.writeAsync { db in
      let itemRowId = try Self.requireLiveItemRowId(db, accountId: self.accountId, itemID: itemID)
      let row = try Self.showRow(db, accountId: self.accountId, itemRowId: itemRowId)
      try Self.saveShowSettings(
        db,
        accountId: self.accountId,
        itemRowId: itemRowId,
        autoDownloadOverride: PodcastShowAutoDownloadOverride.parse(row.autoDownloadOverrideRaw),
        keepLatestOverride: count,
        deleteAfterPlayedOverride: row.deleteAfterPlayedOverride,
        enabledAt: row.enabledAt)
    }
  }

  public func setShowDeleteAfterPlayedOverride(itemID: String, enabled: Bool?) async throws {
    if let feedId = try Self.rssFeedID(for: itemID) {
      try await onRSSFeed { try await $0.setDeleteAfterPlayedOverride(feedId: feedId, enabled: enabled) }
      return
    }

    try await database.writeAsync { db in
      let itemRowId = try Self.requireLiveItemRowId(db, accountId: self.accountId, itemID: itemID)
      let row = try Self.showRow(db, accountId: self.accountId, itemRowId: itemRowId)
      try Self.saveShowSettings(
        db,
        accountId: self.accountId,
        itemRowId: itemRowId,
        autoDownloadOverride: PodcastShowAutoDownloadOverride.parse(row.autoDownloadOverrideRaw),
        keepLatestOverride: row.keepLatestOverride,
        deleteAfterPlayedOverride: enabled,
        enabledAt: row.enabledAt)
    }
  }

  public func setShowIncludeInLatest(itemID: String, enabled: Bool) async throws {
    guard let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return }
    try await onRSSFeed { try await $0.setIncludeInLatest(feedId: feedId, enabled: enabled) }
  }

  public func setShowNotificationOverride(
    itemID: String, override: RSSNotificationOverride
  ) async throws {
    guard let feedId = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return }
    try await onRSSFeed { try await $0.setNotificationOverride(feedId: feedId, override: override) }
  }

  // MARK: - Trim Silences and Voice Boost

  /// Writes only the override column, so the show's other settings, and the record that saves
  /// them, never carry it.
  public func setTrimSilencesOverride(
    itemID: String, override: TrimSilencesShowOverride
  ) async throws {
    try await setShowOverride(.trimSilences, itemID: itemID, rawValue: override.rawValue)
  }

  /// This account's live ABS shows whose override is not `inherit`, keyed by server item id. RSS
  /// feeds are `RSSFeedSettingsStore`'s.
  public func fetchTrimSilencesOverrides() async throws -> [String: TrimSilencesShowOverride] {
    try await fetchShowOverrides(.trimSilences).compactMapValues(TrimSilencesShowOverride.init)
  }

  public func observeTrimSilencesOverrides() -> AsyncStream<[String: TrimSilencesShowOverride]> {
    observeShowOverrides(.trimSilences) { $0.compactMapValues(TrimSilencesShowOverride.init) }
  }

  /// Same shape as the Trim Silences override, for Voice Boost.
  public func setVoiceBoostOverride(itemID: String, override: VoiceBoostShowOverride) async throws {
    try await setShowOverride(.voiceBoost, itemID: itemID, rawValue: override.rawValue)
  }

  public func fetchVoiceBoostOverrides() async throws -> [String: VoiceBoostShowOverride] {
    try await fetchShowOverrides(.voiceBoost).compactMapValues(VoiceBoostShowOverride.init)
  }

  public func observeVoiceBoostOverrides() -> AsyncStream<[String: VoiceBoostShowOverride]> {
    observeShowOverrides(.voiceBoost) { $0.compactMapValues(VoiceBoostShowOverride.init) }
  }

  private func setShowOverride(
    _ column: ShowOverrideColumn, itemID: String, rawValue: String
  ) async throws {
    if let feedId = try Self.rssFeedID(for: itemID) {
      try await onRSSFeed { try await $0.setShowOverride(column, feedId: feedId, rawValue: rawValue) }
      return
    }

    try await database.writeAsync { db in
      let itemRowId = try Self.requireLiveItemRowId(db, accountId: self.accountId, itemID: itemID)
      try db.execute(
        sql: """
          INSERT INTO podcastShowSettings (itemId, accountId, \(column.rawValue))
          VALUES (?, ?, ?)
          ON CONFLICT(itemId) DO UPDATE SET \(column.rawValue) = excluded.\(column.rawValue)
          """,
        arguments: [itemRowId, self.accountId, rawValue])
    }
  }

  /// Runs `body` against the RSS feed store, reporting a feed that is gone as a missing item.
  private func onRSSFeed(_ body: (RSSFeedSettingsStore) async throws -> Void) async throws {
    do {
      try await body(RSSFeedSettingsStore(database: database))
    } catch RSSFeedSettingsStoreError.feedNotFound {
      throw PodcastSettingsStoreError.itemNotFound
    }
  }

  private func fetchShowOverrides(_ column: ShowOverrideColumn) async throws -> [String: String] {
    try await database.readAsync { db in
      try Self.showOverrides(db, column: column, accountId: self.accountId)
    }
  }

  private func observeShowOverrides<Value: Sendable & Equatable>(
    _ column: ShowOverrideColumn, _ transform: @escaping @Sendable ([String: String]) -> Value
  ) -> AsyncStream<Value> {
    let accountId = accountId
    return ObservationBridge.stream(in: database.dbWriter) { db in
      transform(try Self.showOverrides(db, column: column, accountId: accountId))
    }
  }

  /// Raw values that are not `inherit`; an unknown value is dropped by the caller's parse, so it
  /// reads as `inherit` rather than as a setting nobody chose.
  private static func showOverrides(
    _ db: Database, column: ShowOverrideColumn, accountId: Int64
  ) throws -> [String: String] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT item.serverItemId AS serverItemId, settings.\(column.rawValue) AS value
        FROM podcastShowSettings AS settings
        JOIN item ON item.id = settings.itemId
        WHERE settings.accountId = ? AND settings.\(column.rawValue) != 'inherit'
          -- Not a catalogue projection: this resolves the show a settings row names.
          AND item.softDeleted = 0
        """,
      arguments: [accountId])
    var result: [String: String] = [:]
    for row in rows {
      guard let value: String = row["value"] else { continue }
      result[row["serverItemId"]] = value
    }
    return result
  }

  // MARK: - Internals

  private func updateGlobal(
    _ update: @Sendable (inout PodcastSettingsRecord) -> Void
  ) async throws {
    try await database.writeAsync { db in
      var record = try Self.globalRecord(db, accountId: self.accountId)
      update(&record)
      try record.save(db)
    }
  }

  /// The raw shape of a `podcastShowSettings` row (or its absent-row default), read as plain
  /// SQL types rather than decoded through `PodcastShowSettingsRecord`. Decoding an unrecognized
  /// `autoDownloadOverride` string through GRDB's `FetchableRecord` conformance throws instead of
  /// failing closed, which would hide the row entirely.
  private struct ShowRow {
    var autoDownloadOverrideRaw: String
    var keepLatestOverride: Int?
    var deleteAfterPlayedOverride: Bool?
    var enabledAt: Date?
  }

  private struct RSSRow {
    var autoDownloadRaw: String
    var keepLatest: Int?
    var deleteAfterPlayed: Bool?
    var includeInLatest: Bool
    var notificationOverride: RSSNotificationOverride
  }

  private static func globalRecord(_ db: Database, accountId: Int64) throws -> PodcastSettingsRecord {
    try PodcastSettingsRecord.fetchOne(db, key: accountId)
      ?? PodcastSettingsRecord(accountId: accountId)
  }

  private static func globalSettings(_ db: Database, accountId: Int64) throws
    -> PodcastGlobalSettings
  {
    guard let record = try PodcastSettingsRecord.fetchOne(db, key: accountId) else {
      return .defaults
    }
    return PodcastGlobalSettings(
      autoDownloadEnabled: record.autoDownloadEnabled,
      keepLatestCount: record.keepLatestCount,
      deleteAfterPlayed: record.deleteAfterPlayed,
      allowCellularAutoDownload: record.allowCellularAutoDownload,
      enabledAt: record.enabledAt)
  }

  private static func liveItemRowId(_ db: Database, accountId: Int64, itemID: String) throws
    -> Int64?
  {
    try Int64.fetchOne(
      db,
      sql: """
        SELECT id FROM item
        WHERE accountId = ? AND serverItemId = ? AND softDeleted = 0 AND mediaKind = 'podcast'
        """,
      arguments: [accountId, itemID])
  }

  private static func requireLiveItemRowId(_ db: Database, accountId: Int64, itemID: String)
    throws -> Int64
  {
    guard let itemRowId = try liveItemRowId(db, accountId: accountId, itemID: itemID) else {
      throw PodcastSettingsStoreError.itemNotFound
    }
    return itemRowId
  }

  private static func liveRSSFeed(_ db: Database, feedId: Int64) throws -> Bool {
    try Int64.fetchOne(
      db, sql: "SELECT id FROM rssFeed WHERE id = ?", arguments: [feedId]) != nil
  }

  private static func rssFeedID(for itemID: String) throws -> Int64? {
    guard let source = PodcastSourceIdentity(itemId: itemID)?.source else {
      throw PodcastSettingsStoreError.itemNotFound
    }
    guard case .rss(let feedID) = source else { return nil }
    return feedID
  }

  private static func rssRow(_ db: Database, feedId: Int64) throws -> RSSRow {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT autoDownload, keepLatest, deleteAfterPlayed, includeInLatest,
                 notificationOverride
          FROM rssFeedSettings
          WHERE feedId = ?
          """,
        arguments: [feedId])
    else {
      return RSSRow(
        autoDownloadRaw: PodcastShowAutoDownloadOverride.inherit.rawValue,
        keepLatest: nil, deleteAfterPlayed: nil, includeInLatest: true,
        notificationOverride: .inherit)
    }
    return RSSRow(
      autoDownloadRaw: row["autoDownload"],
      keepLatest: row["keepLatest"],
      deleteAfterPlayed: row["deleteAfterPlayed"],
      includeInLatest: row["includeInLatest"],
      notificationOverride: RSSNotificationOverride.parse(row["notificationOverride"]))
  }

  private static func showRow(_ db: Database, accountId: Int64, itemRowId: Int64) throws
    -> ShowRow
  {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT autoDownloadOverride, keepLatestOverride, deleteAfterPlayedOverride, enabledAt
          FROM podcastShowSettings
          WHERE accountId = ? AND itemId = ?
          """,
        arguments: [accountId, itemRowId])
    else {
      return ShowRow(
        autoDownloadOverrideRaw: PodcastShowAutoDownloadOverride.inherit.rawValue,
        keepLatestOverride: nil,
        deleteAfterPlayedOverride: nil,
        enabledAt: nil)
    }
    let overrideRaw: String = row["autoDownloadOverride"]
    let keepLatestOverride: Int? = row["keepLatestOverride"]
    let deleteAfterPlayedOverride: Bool? = row["deleteAfterPlayedOverride"]
    let enabledAt: Date? = row["enabledAt"]
    return ShowRow(
      autoDownloadOverrideRaw: overrideRaw,
      keepLatestOverride: keepLatestOverride,
      deleteAfterPlayedOverride: deleteAfterPlayedOverride,
      enabledAt: enabledAt)
  }

  private static func saveShowSettings(
    _ db: Database,
    accountId: Int64,
    itemRowId: Int64,
    autoDownloadOverride: PodcastShowAutoDownloadOverride,
    keepLatestOverride: Int?,
    deleteAfterPlayedOverride: Bool?,
    enabledAt: Date?
  ) throws {
    let record = PodcastShowSettingsRecord(
      itemId: itemRowId,
      accountId: accountId,
      autoDownloadOverride: autoDownloadOverride,
      keepLatestOverride: keepLatestOverride,
      deleteAfterPlayedOverride: deleteAfterPlayedOverride,
      enabledAt: enabledAt)
    try record.save(db)
  }

  private static func settingsDetail(
    _ db: Database, accountId: Int64, itemID: String
  ) throws -> PodcastShowSettingsDetail? {
    switch PodcastSourceIdentity(itemId: itemID)?.source {
    case nil:
      return nil
    case .rss(let feedId):
      guard try liveRSSFeed(db, feedId: feedId) else { return nil }
      return try nativeRSSShowDetail(db, feedId: feedId)
    case .abs(let itemID):
      guard let itemRowId = try liveItemRowId(db, accountId: accountId, itemID: itemID) else {
        return nil
      }
      return try showDetail(db, accountId: accountId, itemRowId: itemRowId, itemID: itemID)
    }
  }

  private static func showDetail(
    _ db: Database, accountId: Int64, itemRowId: Int64, itemID: String
  ) throws -> PodcastShowSettingsDetail {
    let title =
      try String.fetchOne(db, sql: "SELECT title FROM item WHERE id = ?", arguments: [itemRowId])
      ?? ""
    let global = try globalSettings(db, accountId: accountId)
    let row = try showRow(db, accountId: accountId, itemRowId: itemRowId)
    let override = PodcastShowAutoDownloadOverride.parse(row.autoDownloadOverrideRaw)
    let effective = PodcastEffectiveSettingsResolver.resolve(
      global: global,
      showOverride: override,
      showKeepLatestOverride: row.keepLatestOverride,
      showDeleteAfterPlayedOverride: row.deleteAfterPlayedOverride,
      showEnabledAt: row.enabledAt)
    return PodcastShowSettingsDetail(
      itemID: itemID,
      title: title,
      autoDownloadOverride: override,
      keepLatestOverride: row.keepLatestOverride,
      deleteAfterPlayedOverride: row.deleteAfterPlayedOverride,
      enabledAt: row.enabledAt,
      effective: effective,
      includeInLatest: nil)
  }

  static func nativeRSSShowDetail(
    _ db: Database, feedId: Int64
  ) throws -> PodcastShowSettingsDetail? {
    guard let feed = try RSSFeedRecord.fetchOne(db, key: feedId) else { return nil }
    let title = feed.title ?? ""
    let global = try NativePodcastSettingsRecord.fetchOne(db, key: 1)?.settings ?? .defaults
    let row = try rssRow(db, feedId: feedId)
    let override = PodcastShowAutoDownloadOverride.parse(row.autoDownloadRaw)
    let effective = PodcastEffectiveSettingsResolver.resolve(
      global: global,
      showOverride: override,
      showKeepLatestOverride: row.keepLatest,
      showDeleteAfterPlayedOverride: row.deleteAfterPlayed,
      showEnabledAt: nil)
    guard let itemId = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else {
      throw PodcastSettingsStoreError.itemNotFound
    }
    return PodcastShowSettingsDetail(
      itemID: itemId,
      title: title,
      autoDownloadOverride: override,
      keepLatestOverride: row.keepLatest,
      deleteAfterPlayedOverride: row.deleteAfterPlayed,
      enabledAt: nil,
      effective: effective,
      includeInLatest: row.includeInLatest,
      notificationOverride: row.notificationOverride)
  }

  /// Live podcast shows only, soft-deleted absent, ordered by the item table's own `sortTitle`
  /// convention (`DefaultLibraryReading.observeBrowseList`). One query per emission, not N+1
  /// per-show lookups.
  private static func showSummaries(_ db: Database, accountId: Int64) throws
    -> [PodcastShowSettingsSummary]
  {
    let global = try globalSettings(db, accountId: accountId)
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT item.serverItemId AS itemID, item.title AS title,
               show.autoDownloadOverride AS autoDownloadOverrideRaw,
               show.keepLatestOverride AS keepLatestOverride,
               show.deleteAfterPlayedOverride AS deleteAfterPlayedOverride,
               show.enabledAt AS enabledAt
        FROM item
        JOIN library
          ON library.id = item.libraryId
          AND library.accountId = item.accountId
        LEFT JOIN podcastShowSettings AS show
          ON show.itemId = item.id AND show.accountId = item.accountId
        WHERE item.accountId = ? AND item.mediaKind = 'podcast'
          AND \(ItemVisibilityPredicate.sql)
        ORDER BY item.sortTitle
        """,
      arguments: [accountId])
    let absSummaries = rows.map { row in
      let overrideRaw: String? = row["autoDownloadOverrideRaw"]
      let override = PodcastShowAutoDownloadOverride.parse(
        overrideRaw ?? PodcastShowAutoDownloadOverride.inherit.rawValue)
      let keepLatestOverride: Int? = row["keepLatestOverride"]
      let deleteAfterPlayedOverride: Bool? = row["deleteAfterPlayedOverride"]
      let enabledAt: Date? = row["enabledAt"]
      let effective = PodcastEffectiveSettingsResolver.resolve(
        global: global,
        showOverride: override,
        showKeepLatestOverride: keepLatestOverride,
        showDeleteAfterPlayedOverride: deleteAfterPlayedOverride,
        showEnabledAt: enabledAt)
      let itemID: String = row["itemID"]
      let title: String = row["title"]
      return PodcastShowSettingsSummary(
        itemID: itemID, title: title, autoDownloadOverride: override, effective: effective)
    }

    return try absSummaries + nativeShowSummaries(db)
  }

  static func nativeShowSummaries(_ db: Database) throws -> [PodcastShowSettingsSummary] {
    let global = try NativePodcastSettingsRecord.fetchOne(db, key: 1)?.settings ?? .defaults
    let rssRows = try Row.fetchAll(
      db,
      sql: """
        SELECT feed.id AS feedID, feed.title AS title,
               settings.autoDownload AS autoDownloadRaw,
               settings.keepLatest AS keepLatest,
               settings.deleteAfterPlayed AS deleteAfterPlayed
        FROM rssFeed AS feed
        LEFT JOIN rssFeedSettings AS settings ON settings.feedId = feed.id
        ORDER BY COALESCE(feed.title, '') COLLATE NOCASE, feed.id
        """)
    let rssSummaries = rssRows.compactMap { row -> PodcastShowSettingsSummary? in
      let feedId: Int64 = row["feedID"]
      guard let itemId = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else { return nil }
      let autoDownloadRaw: String? = row["autoDownloadRaw"]
      let title: String? = row["title"]
      let override = PodcastShowAutoDownloadOverride.parse(
        autoDownloadRaw ?? PodcastShowAutoDownloadOverride.inherit.rawValue)
      let effective = PodcastEffectiveSettingsResolver.resolve(
        global: global,
        showOverride: override,
        showKeepLatestOverride: row["keepLatest"],
        showDeleteAfterPlayedOverride: row["deleteAfterPlayed"],
        showEnabledAt: nil)
      return PodcastShowSettingsSummary(
        itemID: itemId,
        title: title ?? "",
        autoDownloadOverride: override,
        effective: effective)
    }
    return rssSummaries
  }

}
