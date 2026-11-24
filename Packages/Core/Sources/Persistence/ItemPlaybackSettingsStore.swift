import Foundation
import GRDB

/// The Persistence-owned copy of the playback rate bounds. Rates are stored as twentieths, so
/// 0.5x...3.0x is represented by steps 10...60. PlayerCore's `PlaybackRateResolution` carries
/// the same bound independently; Persistence must not depend upward on PlayerCore to share it.
public enum ItemPlaybackSettingsRateBounds {
  public static let minimumStep = 10
  public static let maximumStep = 60
  public static let supportedSteps = minimumStep...maximumStep
}

public enum ItemPlaybackSettingsStoreError: Error, Equatable, Sendable {
  case itemNotFound
  case invalidRateStep(Int)
}

/// Account-scoped persistence for per-title playback-rate overrides. Callers use ABS item ids;
/// this store resolves them to the integer `item` row id before touching the settings table.
public struct ItemPlaybackSettingsStore: Sendable {
  private let database: AppDatabase
  private let accountId: Int64

  public init(database: AppDatabase, accountId: Int64) {
    self.database = database
    self.accountId = accountId
  }

  public func fetchOverride(itemID: String) async throws -> Int? {
    try await database.readAsync { db in
      guard
        let itemRowId = try Self.itemRowID(
          db, accountId: self.accountId, itemID: itemID)
      else {
        return nil
      }
      guard
        let rateStep = try Int.fetchOne(
          db,
          sql: """
            SELECT rateStep FROM itemPlaybackSettings
            WHERE accountId = ? AND itemId = ?
            """,
          arguments: [self.accountId, itemRowId])
      else {
        return nil
      }
      return Self.validRateStep(rateStep)
    }
  }

  public func fetchOverrides() async throws -> [String: Int] {
    try await database.readAsync { db in
      try Self.overrides(db, accountId: self.accountId)
    }
  }

  /// One tracked query hydrates the whole bounded override cache. The join includes
  /// soft-deleted items: playback can still start a downloaded tombstoned title, and the lookup
  /// follows `ItemDAO.fetchOne(accountId:serverItemId:)`, not `PodcastSettingsStore.liveItemRowId`.
  public func observeOverrides() -> AsyncStream<[String: Int]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.overrides(db, accountId: self.accountId)
    }
  }

  public func upsertOverride(itemID: String, rateStep: Int) async throws {
    guard Self.isValidRateStep(rateStep) else {
      throw ItemPlaybackSettingsStoreError.invalidRateStep(rateStep)
    }

    try await database.writeAsync { db in
      guard
        let itemRowId = try Self.itemRowID(
          db, accountId: self.accountId, itemID: itemID)
      else {
        throw ItemPlaybackSettingsStoreError.itemNotFound
      }
      let record = ItemPlaybackSettingsRecord(
        itemId: itemRowId, accountId: self.accountId, rateStep: rateStep)
      try record.save(db)
    }
  }

  public func deleteOverride(itemID: String) async throws {
    try await database.writeAsync { db in
      guard
        let itemRowId = try Self.itemRowID(
          db, accountId: self.accountId, itemID: itemID)
      else {
        throw ItemPlaybackSettingsStoreError.itemNotFound
      }
      _ =
        try ItemPlaybackSettingsRecord
        .filter(Column("accountId") == self.accountId)
        .filter(Column("itemId") == itemRowId)
        .deleteAll(db)
    }
  }

  public func deleteAllOverrides() async throws {
    try await database.writeAsync { db in
      _ =
        try ItemPlaybackSettingsRecord
        .filter(Column("accountId") == self.accountId)
        .deleteAll(db)
    }
  }

  // MARK: - Internals

  /// Playback lookup is media-neutral and does not filter `softDeleted`. Unlike
  /// `PodcastSettingsStore.liveItemRowId`, this follows `ItemDAO.fetchOne` because books are valid
  /// playback titles and downloaded titles may remain playable after their library row is tombstoned.
  private static func itemRowID(_ db: Database, accountId: Int64, itemID: String) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: """
        SELECT id FROM item
        WHERE accountId = ? AND serverItemId = ?
        """,
      arguments: [accountId, itemID])
  }

  private static func overrides(_ db: Database, accountId: Int64) throws -> [String: Int] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT item.serverItemId AS itemID, settings.rateStep AS rateStep
        FROM itemPlaybackSettings AS settings
        JOIN item
          ON item.id = settings.itemId AND item.accountId = settings.accountId
        WHERE settings.accountId = ?
        """,
      arguments: [accountId])

    var result: [String: Int] = [:]
    for row in rows {
      let rateStep: Int = row["rateStep"]
      guard let validRateStep = validRateStep(rateStep) else { continue }
      let itemID: String = row["itemID"]
      result[itemID] = validRateStep
    }
    return result
  }

  private static func isValidRateStep(_ rateStep: Int) -> Bool {
    ItemPlaybackSettingsRateBounds.supportedSteps.contains(rateStep)
  }

  private static func validRateStep(_ rateStep: Int) -> Int? {
    isValidRateStep(rateStep) ? rateStep : nil
  }
}
