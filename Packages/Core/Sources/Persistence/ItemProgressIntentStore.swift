import Foundation
import GRDB

public enum ItemProgressIntentStoreError: Error, Equatable, Sendable {
  case itemNotFound(String)
  case episodeNotFound(String)
}

/// One episode's share of a bulk progress change. `currentTime` is that episode's own completed
/// position, resolved by the caller from its own cached row, never the show's (the sum of every
/// episode).
public struct EpisodeProgressChange: Sendable, Equatable {
  public let episodeID: String
  public let currentTime: Double

  public init(episodeID: String, currentTime: Double) {
    self.episodeID = episodeID
    self.currentTime = currentTime
  }
}

/// Atomically applies an explicit progress change (item-level, or scoped to one podcast episode)
/// and queues the matching one-shot server mutation. Each call starts a new coalescing segment:
/// reset and finished/un-finished transitions are boundaries that must never merge across one
/// another.
public struct ItemProgressIntentStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) throws {
    self.database = database
    _ = try OutboxStore(database: database)
  }

  /// `episodeID` selects the identity this writes: `nil` is the item's own progress row, and a
  /// server episode id is that episode's row. The two are never the same row (two partial unique
  /// indices), so a finished episode never finishes its show.
  public func setProgress(
    itemID: String,
    episodeID: String? = nil,
    currentTime: Double,
    isFinished: Bool,
    originKey: String
  ) throws {
    try database.write { db in
      try Self.setProgress(
        itemID: itemID,
        episodeID: episodeID,
        currentTime: currentTime,
        isFinished: isFinished,
        originKey: originKey,
        in: db)
    }
  }

  public func setProgressAsync(
    itemID: String,
    episodeID: String? = nil,
    currentTime: Double,
    isFinished: Bool,
    originKey: String
  ) async throws {
    try await database.writeAsync { db in
      try Self.setProgress(
        itemID: itemID,
        episodeID: episodeID,
        currentTime: currentTime,
        isFinished: isFinished,
        originKey: originKey,
        in: db)
    }
  }

  private static func setProgress(
    itemID: String,
    episodeID: String?,
    currentTime: Double,
    isFinished: Bool,
    originKey: String,
    in db: Database
  ) throws {
    let item = try Self.item(itemID, in: db)
    try Self.apply(
      db, item: item, itemID: itemID,
      episodeRowID: try Self.episodeRowID(episodeID, itemRowID: item.rowID, in: db),
      currentTime: currentTime, isFinished: isFinished, originKey: originKey)
  }

  /// Resets the audio position (or one episode's) to 0 and unfinished. The wire leg is a
  /// `progressReset` operation, which deletes the server row so other devices can see the reset
  /// as loss of row identity (ADR 0011); a mixed-format item's ebook position is restored from the
  /// server afterwards.
  public func resetProgress(itemID: String, episodeID: String? = nil, originKey: String) throws {
    try database.write { db in
      try Self.resetProgress(itemID: itemID, episodeID: episodeID, originKey: originKey, in: db)
    }
  }

  public func resetProgressAsync(
    itemID: String, episodeID: String? = nil, originKey: String
  ) async throws {
    try await database.writeAsync { db in
      try Self.resetProgress(itemID: itemID, episodeID: episodeID, originKey: originKey, in: db)
    }
  }

  private static func resetProgress(
    itemID: String, episodeID: String?, originKey: String, in db: Database
  ) throws {
    let item = try Self.item(itemID, in: db)
    try Self.apply(
      db, item: item, itemID: itemID,
      episodeRowID: try Self.episodeRowID(episodeID, itemRowID: item.rowID, in: db),
      currentTime: 0, isFinished: false, originKey: originKey, resetsServerRow: true)
  }

  /// Clears only the ebook and shared-finish fields. The audio position is kept for mixed-format
  /// books: the `progressReset` operation deletes the server row and then restores the server's
  /// audio position.
  public func resetEbookProgress(itemID: String, originKey: String) throws {
    try database.write { db in
      try Self.resetEbookProgress(itemID: itemID, originKey: originKey, in: db)
    }
  }

  public func resetEbookProgressAsync(itemID: String, originKey: String) async throws {
    try await database.writeAsync { db in
      try Self.resetEbookProgress(itemID: itemID, originKey: originKey, in: db)
    }
  }

  /// Changes only Continue Listening visibility and queues the matching field-only progress
  /// mutation in the same transaction. Audio position, finished state, and reading state are left
  /// untouched.
  public func setContinueListeningVisibility(
    itemID: String,
    episodeID: String? = nil,
    isHidden: Bool,
    originKey: String
  ) throws {
    try database.write { db in
      try Self.setContinueListeningVisibility(
        itemID: itemID,
        episodeID: episodeID,
        isHidden: isHidden,
        originKey: originKey,
        in: db)
    }
  }

  public func setContinueListeningVisibilityAsync(
    itemID: String,
    episodeID: String? = nil,
    isHidden: Bool,
    originKey: String
  ) async throws {
    try await database.writeAsync { db in
      try Self.setContinueListeningVisibility(
        itemID: itemID,
        episodeID: episodeID,
        isHidden: isHidden,
        originKey: originKey,
        in: db)
    }
  }

  private static func setContinueListeningVisibility(
    itemID: String,
    episodeID: String?,
    isHidden: Bool,
    originKey: String,
    in db: Database
  ) throws {
    let item = try Self.item(itemID, in: db)
    let episodeRowID = try Self.episodeRowID(episodeID, itemRowID: item.rowID, in: db)
    let existing =
      try MediaProgressRecord
      .filter(Column("accountId") == item.record.accountId)
      .filter(Column("itemId") == item.rowID)
      .filter(Column("podcastEpisodeId") == episodeRowID)
      .fetchOne(db)
    let localSequence = (existing?.localSequence ?? 0) + 1

    var progress =
      existing
      ?? MediaProgressRecord(
        accountId: item.record.accountId,
        itemId: item.rowID,
        podcastEpisodeId: episodeRowID,
        currentTime: 0,
        isFinished: false,
        localSequence: localSequence,
        origin: .local,
        originKey: originKey)
    progress.hideFromContinueListening = isHidden
    progress.localSequence = localSequence
    progress.origin = .local
    progress.originKey = originKey
    try progress.save(db)

    _ = try OutboxStore.enqueueContinueListeningVisibility(
      db,
      accountId: item.record.accountId,
      entityKey: itemID,
      podcastEpisodeId: episodeRowID,
      localSequence: localSequence,
      hideFromContinueListening: isHidden,
      clientOperationId: UUID().uuidString)
  }

  private static func resetEbookProgress(
    itemID: String, originKey: String, in db: Database
  ) throws {
    let item = try Self.item(itemID, in: db)
    let existing =
      try MediaProgressRecord
      .filter(Column("accountId") == item.record.accountId)
      .filter(Column("itemId") == item.rowID)
      .filter(Column("podcastEpisodeId") == nil)
      .fetchOne(db)
    let localSequence = (existing?.localSequence ?? 0) + 1
    var progress =
      existing
      ?? MediaProgressRecord(
        accountId: item.record.accountId,
        itemId: item.rowID,
        podcastEpisodeId: nil,
        currentTime: 0,
        isFinished: false,
        localSequence: localSequence,
        origin: .local,
        originKey: originKey)
    progress.ebookProgress = 0
    progress.ebookLocation = nil
    progress.readingPositionJSON = nil
    progress.isFinished = false
    progress.localSequence = localSequence
    progress.origin = .local
    progress.originKey = originKey
    try progress.save(db)
    let operation = try OutboxStore.enqueueProgressReset(
      db,
      accountId: item.record.accountId,
      entityKey: itemID,
      podcastEpisodeId: nil,
      medium: .ebook,
      localSequence: localSequence)
    if progress.localSequence != operation.localSequence {
      progress.localSequence = operation.localSequence
      try progress.update(db)
    }
  }

  /// Every episode in one transaction and one coalescing segment apiece. "Mark all as played" over
  /// a filtered list is one user action: a half-applied result would leave part of a show finished
  /// with nothing to say which part, and the single-episode path would cost one drain request per
  /// episode.
  public func setProgress(
    itemID: String,
    episodes: [EpisodeProgressChange],
    isFinished: Bool,
    originKey: String
  ) throws {
    guard episodes.isEmpty == false else { return }
    try database.write { db in
      try Self.setProgress(
        itemID: itemID, episodes: episodes, isFinished: isFinished, originKey: originKey, in: db)
    }
  }

  public func setProgressAsync(
    itemID: String,
    episodes: [EpisodeProgressChange],
    isFinished: Bool,
    originKey: String
  ) async throws {
    guard episodes.isEmpty == false else { return }
    try await database.writeAsync { db in
      try Self.setProgress(
        itemID: itemID, episodes: episodes, isFinished: isFinished, originKey: originKey, in: db)
    }
  }

  private static func setProgress(
    itemID: String,
    episodes: [EpisodeProgressChange],
    isFinished: Bool,
    originKey: String,
    in db: Database
  ) throws {
    let item = try Self.item(itemID, in: db)
    for change in episodes {
      try Self.apply(
        db, item: item, itemID: itemID,
        episodeRowID: try Self.episodeRowID(
          change.episodeID, itemRowID: item.rowID, in: db),
        currentTime: change.currentTime, isFinished: isFinished, originKey: originKey)
    }
  }

  private static func item(_ itemID: String, in db: Database) throws -> (
    record: ItemRecord, rowID: Int64
  ) {
    guard
      let item =
        try ItemRecord
        .filter(Column("serverItemId") == itemID)
        .filter(Column("softDeleted") == false)
        .fetchOne(db),
      let itemRowID = item.id
    else {
      throw ItemProgressIntentStoreError.itemNotFound(itemID)
    }
    return (item, itemRowID)
  }

  /// Resolved to the local row id the progress and outbox rows are both keyed by. A soft-deleted
  /// episode still resolves: the download and its position outlive the tombstone (a later
  /// traversal can revive the row), as with `DownloadStore.tombstonedEpisodeDownloads`.
  private static func episodeRowID(
    _ episodeID: String?, itemRowID: Int64, in db: Database
  ) throws -> Int64? {
    guard let episodeID else { return nil }
    guard
      let episode =
        try PodcastEpisodeRecord
        .filter(Column("itemId") == itemRowID)
        .filter(Column("serverEpisodeId") == episodeID)
        .fetchOne(db),
      let resolved = episode.id
    else {
      throw ItemProgressIntentStoreError.episodeNotFound(episodeID)
    }
    return resolved
  }

  private static func apply(
    _ db: Database,
    item: (record: ItemRecord, rowID: Int64),
    itemID: String,
    episodeRowID: Int64?,
    currentTime: Double,
    isFinished: Bool,
    originKey: String,
    resetsServerRow: Bool = false
  ) throws {
    let clientOperationID = UUID().uuidString
    let itemRowID = item.rowID
    let accountID = item.record.accountId

    let existing =
      try MediaProgressRecord
      .filter(Column("accountId") == accountID)
      .filter(Column("itemId") == itemRowID)
      .filter(Column("podcastEpisodeId") == episodeRowID)
      .fetchOne(db)
    let localSequence = (existing?.localSequence ?? 0) + 1

    var progress =
      existing
      ?? MediaProgressRecord(
        accountId: accountID,
        itemId: itemRowID,
        podcastEpisodeId: episodeRowID,
        currentTime: currentTime,
        isFinished: isFinished,
        localSequence: localSequence,
        origin: .local,
        originKey: originKey)
    progress.currentTime = currentTime
    progress.isFinished = isFinished
    progress.hideFromContinueListening = false
    progress.localSequence = localSequence
    progress.origin = .local
    progress.originKey = originKey
    try progress.save(db)

    // `entityKey` is always the show's server item id; the drain resolves `podcastEpisodeId` to
    // a server episode id at send time and routes accordingly.
    if resetsServerRow {
      _ = try OutboxStore.enqueueProgressReset(
        db,
        accountId: accountID,
        entityKey: itemID,
        podcastEpisodeId: episodeRowID,
        medium: .audio,
        localSequence: localSequence,
        clientOperationId: clientOperationID)
      return
    }
    _ = try OutboxStore.enqueueProgress(
      db,
      accountId: accountID,
      entityKey: itemID,
      podcastEpisodeId: episodeRowID,
      coalescingKey: "explicit:\(clientOperationID)",
      localSequence: localSequence,
      payload: OutboxProgressPayload(
        currentTime: currentTime,
        isFinished: isFinished,
        accumulatedDeltaSeconds: 0),
      clientOperationId: clientOperationID)
  }
}
