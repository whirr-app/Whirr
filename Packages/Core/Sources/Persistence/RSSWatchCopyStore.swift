import Foundation
import GRDB

/// The phone's desired set for the active Watch: `rssWatchCopy`, plus the one-row `rssWatchCopySet`
/// (ADR 0019). Device-owned; no account foreign key, no cloud sync.
///
/// The Watch is authoritative about storage. A finished download on the Watch is not "On Watch":
/// only an inventory `ready` entry for the same revision makes a copy `delivered`. A revision the
/// Watch reports against a row it no longer matches is ignored, so a stale report cannot move a
/// newer request.
public struct RSSWatchCopyStore: Sendable {
  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Requests

  /// The listener asked to send this episode, so it enters the offer as `wanted`. A terminal row
  /// (`removed`, `declined`, `failed`, `delivered`) is re-requested with a bumped revision; an
  /// active request keeps its revision and its place in the offer.
  @discardableResult
  public func request(episodeId: Int64, now: Date) async throws -> RSSWatchCopy {
    try await database.writeAsync { db in
      guard try Self.episodeExists(db, episodeId: episodeId) else {
        throw RSSWatchCopyStoreError.episodeNotFound
      }

      if var existing = try RSSWatchCopy.fetchOne(db, key: episodeId) {
        if WatchCopyArithmetic.isTerminal(existing.state) {
          existing.revision += 1
          existing.state = .wanted
          existing.removedBy = nil
          existing.declineReason = nil
          existing.sourceBytes = nil
          existing.failedAt = nil
          existing.requestedAt = now
          existing.updatedAt = now
          try existing.update(db)
          try Self.bumpGeneration(in: db)
          return existing
        }
        return existing
      }

      let record = RSSWatchCopy(
        episodeId: episodeId, revision: 1, state: .wanted, requestedAt: now, updatedAt: now)
      try record.insert(db)
      try Self.bumpGeneration(in: db)
      return record
    }
  }

  /// Phone-initiated removal. Returns `nil` when there was nothing to remove; the episode must
  /// still exist, because a missing episode is a caller bug rather than an empty set.
  public func removeFromWatch(episodeId: Int64, now: Date) async throws -> RSSWatchCopy? {
    try await database.writeAsync { db in
      guard try Self.episodeExists(db, episodeId: episodeId) else {
        throw RSSWatchCopyStoreError.episodeNotFound
      }
      guard var copy = try RSSWatchCopy.fetchOne(db, key: episodeId) else { return nil }
      let wasRemoved = copy.state == .removed
      copy.state = .removed
      copy.removedBy = .phone
      copy.declineReason = nil
      copy.failedAt = nil
      copy.updatedAt = now
      try copy.update(db)
      if wasRemoved == false {
        try Self.bumpGeneration(in: db)
      }
      return copy
    }
  }

  /// A publisher move, allowed only while the row still carries the revision the caller started
  /// with. Returns false for a stale revision, an absent row, or a move the state machine does not
  /// allow, and the caller treats all three the same: nothing happened.
  public func transition(
    episodeId: Int64, revision: Int64, to target: RSSWatchCopyState, now: Date
  ) async throws -> Bool {
    try await database.writeAsync { db in
      guard var copy = try RSSWatchCopy.fetchOne(db, key: episodeId),
        copy.revision == revision,
        copy.state != target,
        Self.acceptsTransition(from: copy.state, to: target)
      else { return false }

      copy.state = target
      copy.updatedAt = now
      switch target {
      case .failed:
        copy.failedAt = now
      case .wanted:
        copy.failedAt = nil
        copy.sourceBytes = nil
      default:
        break
      }
      try copy.update(db)
      return true
    }
  }

  // MARK: - Reads

  /// Every row, newest request first: the order the next offer lists them in.
  public func copies() async throws -> [RSSWatchCopy] {
    try await database.readAsync { db in
      try RSSWatchCopy.fetchAll(
        db,
        sql: "SELECT * FROM rssWatchCopy ORDER BY requestedAt DESC, episodeId DESC")
    }
  }

  public func copy(episodeId: Int64) async throws -> RSSWatchCopy? {
    try await database.readAsync { db in try RSSWatchCopy.fetchOne(db, key: episodeId) }
  }

  public func setState() async throws -> RSSWatchCopySetState {
    try await database.readAsync { db in
      let record =
        try RSSWatchCopySetRecord.fetchOne(db, key: RSSWatchCopySetRecord.singletonID)
        ?? RSSWatchCopySetRecord()
      return RSSWatchCopySetState(record)
    }
  }

  /// The desired set and the Watch's set state, newest request first, for the phone's On Apple
  /// Watch screen and the episode menu's projection. Unchanged values are suppressed, so a write
  /// that leaves both equal does not wake the UI.
  public func observe() -> AsyncStream<RSSWatchCopyObservation> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          RSSWatchCopyObservation(
            copies: try RSSWatchCopy.fetchAll(
              db, sql: "SELECT * FROM rssWatchCopy ORDER BY requestedAt DESC, episodeId DESC"),
            set: RSSWatchCopySetState(
              try RSSWatchCopySetRecord.fetchOne(db, key: RSSWatchCopySetRecord.singletonID)
                ?? RSSWatchCopySetRecord()))
        }
        .removeDuplicates())
  }

  /// What the next offer lists: everything not removed or declined, newest request first. A row
  /// declined for storage stays, because the Watch takes it back once it has room.
  public func desiredEpisodes() async throws -> [RSSWatchCopy] {
    try await database.readAsync { db in
      try RSSWatchCopy.fetchAll(
        db,
        sql: """
          SELECT * FROM rssWatchCopy
          WHERE state != 'removed'
            AND (state != 'declined' OR declineReason = 'storageFull')
          ORDER BY requestedAt DESC, episodeId DESC
          """)
    }
  }

  /// The phone account boundary (the App calls it): no rows. The generation moves on rather than
  /// back to 0, because the Watch ignores any offer at or below the last generation it applied; the
  /// next (empty) offer is what tells it to drop the previous account's copies. The Watch's
  /// identity, sequence and budget describe the Watch, not the phone account, so they stay.
  public func clearForAccountChange() async throws {
    try await database.writeAsync { db in
      let hadRows = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM rssWatchCopy)") ?? false
      try db.execute(sql: "DELETE FROM rssWatchCopy")
      if hadRows { try Self.bumpGeneration(in: db) }
    }
  }

  // MARK: - Unfollow

  /// Called inside an unfollow's transaction. The copies themselves cascade with their episodes,
  /// but the Watch still holds those files: a bumped generation is the only signal that makes the
  /// next offer tell it to drop them.
  static func noteFeedRemoval(in db: Database, feedId: Int64) throws {
    let holdsCopies =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(
            SELECT 1 FROM rssWatchCopy AS copy
            JOIN rssEpisode AS episode ON episode.id = copy.episodeId
            WHERE episode.feedId = ? AND copy.state <> 'removed'
          )
          """,
        arguments: [feedId]) ?? false
    if holdsCopies {
      try bumpGeneration(in: db)
    }
  }

  // MARK: - Internals

  /// Declined for storage: still offered, and the Watch may take it back.
  static func isWaitingForRoom(_ copy: RSSWatchCopy) -> Bool {
    copy.state == .declined && copy.declineReason == .storageFull
  }

  /// The publisher's state whitelist. Each move preserves the revision the caller matched. A row
  /// stays a member of the offer in every allowed move, so none of them moves the generation on.
  private static func acceptsTransition(
    from current: RSSWatchCopyState, to target: RSSWatchCopyState
  ) -> Bool {
    switch target {
    case .sending:
      return current == .wanted || current == .waitingForWatch
    case .waitingForWatch:
      return current == .wanted || current == .waitingForWatch
    case .wanted:
      return current == .waitingForWatch
    case .failed:
      return current == .sending
    case .delivered, .removed, .declined:
      return false
    }
  }

  private static func episodeExists(_ db: Database, episodeId: Int64) throws -> Bool {
    try Bool.fetchOne(
      db, sql: "SELECT EXISTS(SELECT 1 FROM rssEpisode WHERE id = ?)", arguments: [episodeId])
      ?? false
  }

  private static func bumpGeneration(in db: Database) throws {
    try db.execute(
      sql: "UPDATE rssWatchCopySet SET generation = generation + 1 WHERE id = 1")
  }
}
