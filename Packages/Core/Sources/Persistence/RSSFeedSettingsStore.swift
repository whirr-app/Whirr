import Foundation
import GRDB

public enum RSSFeedSettingsStoreError: Error, Equatable, Sendable {
  case feedNotFound
  case invalidKeepLatest(Int)
  case invalidRateStep(Int)
}

/// One feed's effective settings: the ABS resolution result plus the two RSS-only knobs.
public struct RSSFeedEffectiveSettings: Sendable, Equatable {
  public var effective: PodcastEffectiveSettings
  public var rateStep: Int?
  public var includeInLatest: Bool
  public var notificationOverride: RSSNotificationOverride

  public init(
    effective: PodcastEffectiveSettings, rateStep: Int?, includeInLatest: Bool,
    notificationOverride: RSSNotificationOverride = .inherit
  ) {
    self.effective = effective
    self.rateStep = rateStep
    self.includeInLatest = includeInLatest
    self.notificationOverride = notificationOverride
  }
}

/// The RSS transposition of the ABS per-show settings row. The resolver is shared so the two
/// tri-state folds can never drift. Keyed by feed, with no account parameter: native
/// subscriptions, and their settings, survive logout.
public struct RSSFeedSettingsStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func settings(feedId: Int64) async throws -> RSSFeedSettingsRecord? {
    try await database.readAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      return try RSSFeedSettingsRecord.fetchOne(db, key: feedId)
    }
  }

  public func updateSettings(
    feedId: Int64,
    autoDownload: PodcastShowAutoDownloadOverride,
    keepLatest: Int?,
    deleteAfterPlayed: Bool?,
    rateStep: Int?,
    includeInLatest: Bool,
    notificationOverride: RSSNotificationOverride = .inherit
  ) async throws {
    try Self.validate(keepLatest: keepLatest, rateStep: rateStep)
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings
          (feedId, autoDownload, keepLatest, deleteAfterPlayed, rateStep, includeInLatest,
           notificationOverride)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT (feedId) DO UPDATE SET
            autoDownload = excluded.autoDownload, keepLatest = excluded.keepLatest,
            deleteAfterPlayed = excluded.deleteAfterPlayed, rateStep = excluded.rateStep,
            includeInLatest = excluded.includeInLatest,
            notificationOverride = excluded.notificationOverride
          """,
        arguments: [
          feedId, autoDownload.rawValue, keepLatest, deleteAfterPlayed, rateStep, includeInLatest,
          notificationOverride.rawValue,
        ])
    }
  }

  public func setAutoDownloadOverride(
    feedId: Int64, override: PodcastShowAutoDownloadOverride
  ) async throws {
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (feedId, autoDownload)
          VALUES (?, ?)
          ON CONFLICT(feedId) DO UPDATE SET autoDownload = excluded.autoDownload
          """,
        arguments: [feedId, override.rawValue])
    }
  }

  public func setKeepLatestOverride(feedId: Int64, count: Int?) async throws {
    if let count, count < 0 {
      throw RSSFeedSettingsStoreError.invalidKeepLatest(count)
    }
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (feedId, keepLatest)
          VALUES (?, ?)
          ON CONFLICT(feedId) DO UPDATE SET keepLatest = excluded.keepLatest
          """,
        arguments: [feedId, count])
    }
  }

  public func setDeleteAfterPlayedOverride(feedId: Int64, enabled: Bool?) async throws {
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (feedId, deleteAfterPlayed)
          VALUES (?, ?)
          ON CONFLICT(feedId) DO UPDATE SET deleteAfterPlayed = excluded.deleteAfterPlayed
          """,
        arguments: [feedId, enabled])
    }
  }

  public func setIncludeInLatest(feedId: Int64, enabled: Bool) async throws {
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (feedId, includeInLatest)
          VALUES (?, ?)
          ON CONFLICT(feedId) DO UPDATE SET includeInLatest = excluded.includeInLatest
          """,
        arguments: [feedId, enabled])
    }
  }

  public func notificationOverride(feedId: Int64) async throws -> RSSNotificationOverride {
    try await database.readAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      let raw = try String.fetchOne(
        db, sql: "SELECT notificationOverride FROM rssFeedSettings WHERE feedId = ?",
        arguments: [feedId])
      return RSSNotificationOverride.parse(raw)
    }
  }

  public func setNotificationOverride(
    feedId: Int64, override: RSSNotificationOverride
  ) async throws {
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (feedId, notificationOverride)
          VALUES (?, ?)
          ON CONFLICT(feedId) DO UPDATE SET notificationOverride = excluded.notificationOverride
          """,
        arguments: [feedId, override.rawValue])
    }
  }

  // MARK: - Trim Silences and Voice Boost

  public func setTrimSilencesOverride(
    feedId: Int64, override: TrimSilencesShowOverride
  ) async throws {
    try await setShowOverride(.trimSilences, feedId: feedId, rawValue: override.rawValue)
  }

  /// Every feed whose override is not `inherit`.
  public func fetchTrimSilencesOverrides() async throws -> [Int64: TrimSilencesShowOverride] {
    try await database.readAsync { db in try Self.showOverrides(db, column: .trimSilences) }
      .compactMapValues(TrimSilencesShowOverride.init)
  }

  public func observeTrimSilencesOverrides() -> AsyncStream<[Int64: TrimSilencesShowOverride]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.showOverrides(db, column: .trimSilences)
        .compactMapValues(TrimSilencesShowOverride.init)
    }
  }

  /// Same shape as the Trim Silences override, for Voice Boost.
  public func setVoiceBoostOverride(feedId: Int64, override: VoiceBoostShowOverride) async throws {
    try await setShowOverride(.voiceBoost, feedId: feedId, rawValue: override.rawValue)
  }

  public func fetchVoiceBoostOverrides() async throws -> [Int64: VoiceBoostShowOverride] {
    try await database.readAsync { db in try Self.showOverrides(db, column: .voiceBoost) }
      .compactMapValues(VoiceBoostShowOverride.init)
  }

  public func observeVoiceBoostOverrides() -> AsyncStream<[Int64: VoiceBoostShowOverride]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.showOverrides(db, column: .voiceBoost).compactMapValues(VoiceBoostShowOverride.init)
    }
  }

  /// An upsert of the one column, like `setRateOverride`, so no whole-row writer is involved.
  func setShowOverride(_ column: ShowOverrideColumn, feedId: Int64, rawValue: String) async throws {
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (feedId, \(column.rawValue))
          VALUES (?, ?)
          ON CONFLICT(feedId) DO UPDATE SET \(column.rawValue) = excluded.\(column.rawValue)
          """,
        arguments: [feedId, rawValue])
    }
  }

  private static func showOverrides(
    _ db: Database, column: ShowOverrideColumn
  ) throws -> [Int64: String] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT feedId, \(column.rawValue) AS value FROM rssFeedSettings
        WHERE \(column.rawValue) != 'inherit'
        """)
    var result: [Int64: String] = [:]
    for row in rows {
      guard let value: String = row["value"] else { continue }
      result[row["feedId"]] = value
    }
    return result
  }

  // MARK: - Playback rate

  /// Reads only a valid per-feed playback override. Invalid legacy values fail closed to the
  /// inherited global rate, matching `ItemPlaybackSettingsStore`'s bounded read behavior.
  public func fetchRateOverride(feedId: Int64) async throws -> Int? {
    try await database.readAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      guard
        let rateStep = try Int.fetchOne(
          db, sql: "SELECT rateStep FROM rssFeedSettings WHERE feedId = ?", arguments: [feedId])
      else { return nil }
      return Self.validRateStep(rateStep)
    }
  }

  public func fetchRateOverrides() async throws -> [Int64: Int] {
    try await database.readAsync { db in
      try Self.rateOverrides(db)
    }
  }

  public func observeRateOverrides() -> AsyncStream<[Int64: Int]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.rateOverrides(db)
    }
  }

  public func setRateOverride(feedId: Int64, rateStep: Int) async throws {
    guard Self.validRateStep(rateStep) != nil else {
      throw RSSFeedSettingsStoreError.invalidRateStep(rateStep)
    }
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (feedId, rateStep)
          VALUES (?, ?)
          ON CONFLICT(feedId) DO UPDATE SET rateStep = excluded.rateStep
          """,
        arguments: [feedId, rateStep])
    }
  }

  public func clearRateOverride(feedId: Int64) async throws {
    try await database.writeAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      try db.execute(
        sql: "UPDATE rssFeedSettings SET rateStep = NULL WHERE feedId = ?",
        arguments: [feedId])
    }
  }

  /// Clears only playback-rate columns. The feed and every other device-owned settings column
  /// remain in place, so logout cannot erase native subscriptions or their download policy.
  public func clearAllRateOverrides() async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeedSettings SET rateStep = NULL")
    }
  }

  /// RSS feeds have no per-feed activation stamp yet, so the effective floor is the global one;
  /// per-feed floor semantics belong to the refresh automation (`decidedStamp`), not this table.
  public func effectiveSettings(
    feedId: Int64, global: PodcastGlobalSettings
  ) async throws -> RSSFeedEffectiveSettings {
    try await database.readAsync { db in
      try Self.requireFeed(db, feedId: feedId)
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT autoDownload, keepLatest, deleteAfterPlayed, rateStep, includeInLatest,
                 notificationOverride
          FROM rssFeedSettings WHERE feedId = ?
          """,
        arguments: [feedId])
      return Self.resolve(row: row, global: global)
    }
  }

  public func effectiveSettingsForAllFeeds(
    global: PodcastGlobalSettings
  ) async throws -> [Int64: RSSFeedEffectiveSettings] {
    try await database.readAsync { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT rssFeed.id AS feedId,
                 rssFeedSettings.autoDownload AS autoDownload,
                 rssFeedSettings.keepLatest AS keepLatest,
                 rssFeedSettings.deleteAfterPlayed AS deleteAfterPlayed,
                 rssFeedSettings.rateStep AS rateStep,
                 rssFeedSettings.includeInLatest AS includeInLatest,
                 rssFeedSettings.notificationOverride AS notificationOverride
          FROM rssFeed
          LEFT JOIN rssFeedSettings ON rssFeedSettings.feedId = rssFeed.id
          """)
      return Dictionary(
        uniqueKeysWithValues: rows.map { row in
          let feedId: Int64 = row["feedId"]
          return (feedId, Self.resolve(row: row, global: global))
        })
    }
  }

  private static func requireFeed(_ db: Database, feedId: Int64) throws {
    guard try Int64.fetchOne(db, sql: "SELECT id FROM rssFeed WHERE id = ?", arguments: [feedId]) != nil
    else { throw RSSFeedSettingsStoreError.feedNotFound }
  }

  private static func resolve(row: Row?, global: PodcastGlobalSettings) -> RSSFeedEffectiveSettings {
    let autoDownload: String = row?["autoDownload"] ?? PodcastShowAutoDownloadOverride.inherit.rawValue
    let effective = PodcastEffectiveSettingsResolver.resolve(
      global: global,
      showOverride: PodcastShowAutoDownloadOverride.parse(autoDownload),
      showKeepLatestOverride: row?["keepLatest"],
      showDeleteAfterPlayedOverride: row?["deleteAfterPlayed"],
      showEnabledAt: nil)
    return RSSFeedEffectiveSettings(
      effective: effective,
      rateStep: row?["rateStep"],
      includeInLatest: row?["includeInLatest"] ?? true,
      notificationOverride: RSSNotificationOverride.parse(row?["notificationOverride"]))
  }

  private static func validate(keepLatest: Int?, rateStep: Int?) throws {
    if let keepLatest, keepLatest < 0 {
      throw RSSFeedSettingsStoreError.invalidKeepLatest(keepLatest)
    }
    if let rateStep, validRateStep(rateStep) == nil {
      throw RSSFeedSettingsStoreError.invalidRateStep(rateStep)
    }
  }

  private static func validRateStep(_ rateStep: Int) -> Int? {
    ItemPlaybackSettingsRateBounds.supportedSteps.contains(rateStep) ? rateStep : nil
  }

  private static func rateOverrides(_ db: Database) throws -> [Int64: Int] {
    let rows = try Row.fetchAll(
      db,
      sql: "SELECT feedId, rateStep FROM rssFeedSettings WHERE rateStep IS NOT NULL")
    var result: [Int64: Int] = [:]
    for row in rows {
      let rateStep: Int = row["rateStep"]
      guard let validRateStep = validRateStep(rateStep) else { continue }
      let feedId: Int64 = row["feedId"]
      result[feedId] = validRateStep
    }
    return result
  }
}
