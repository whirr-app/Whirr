import Foundation
import GRDB

public enum RSSDownloadStoreError: Error, Equatable, Sendable {
  case downloadNotFound(Int64)
  case episodeNotFound(Int64)
  case illegalTransition(from: DownloadState, to: DownloadState)
  case completionRequiresVerifiedFinalSize
  case completionRequiresRelativePath
  case finalizeDeletionRequiresDeletingState(Int64)
}

/// Persistence for the device-owned `rssDownload` spine.  It contains no network or file I/O;
/// `RSSFileStore` pairs with it for those.
public struct RSSDownloadStore: Sendable {
  let database: AppDatabase

  public static let legalTransitions: [DownloadState: Set<DownloadState>] = DownloadStore.legalTransitions

  public init(database: AppDatabase) throws {
    self.database = database
    try database.write { db in
      // A force-quit leaves an in-flight RSS transfer untrustworthy, as for ABS media.
      try db.execute(
        sql: "UPDATE rssDownload SET state = ?, updatedAt = ? WHERE state = ?",
        arguments: [DownloadState.interrupted.rawValue, Date(), DownloadState.downloading.rawValue])
    }
  }

  public func fetch(downloadId: Int64) throws -> RSSDownloadRecord? {
    try database.read { db in try RSSDownloadRecord.fetchOne(db, key: downloadId) }
  }

  public func fetchAsync(downloadId: Int64) async throws -> RSSDownloadRecord? {
    try await database.readAsync { db in try RSSDownloadRecord.fetchOne(db, key: downloadId) }
  }

  public func fetch(episodeId: Int64) throws -> RSSDownloadRecord? {
    try database.read { db in try Self.fetch(episodeId: episodeId, in: db) }
  }

  public func fetchAsync(episodeId: Int64) async throws -> RSSDownloadRecord? {
    try await database.readAsync { db in try Self.fetch(episodeId: episodeId, in: db) }
  }

  public func fetchAll() throws -> [RSSDownloadRecord] {
    try database.read { db in try RSSDownloadRecord.fetchAll(db) }
  }

  public func fetchAllAsync() async throws -> [RSSDownloadRecord] {
    try await database.readAsync { db in try RSSDownloadRecord.fetchAll(db) }
  }

  /// Rows retained only because a refresh stopped listing their episode.  Retention is a
  /// reversible sync inference; callers may reclaim these rows only through an explicit user
  /// action, never through launch integrity recovery.
  public func tombstonedEpisodeDownloadsAsync() async throws -> [RSSDownloadRecord] {
    try await database.readAsync { db in
      try RSSDownloadRecord.fetchAll(
        db,
        sql: """
          SELECT download.* FROM rssDownload AS download
          JOIN rssEpisode AS episode ON episode.id = download.episodeId
          JOIN rssFeed AS feed ON feed.id = episode.feedId
          WHERE episode.retained = 1 AND episode.lastSeenGeneration < feed.refreshGeneration
          ORDER BY download.id
          """)
    }
  }

  /// Atomically claims every RSS row for a user-initiated device purge.  The returned snapshots
  /// preserve the pre-mark states so the coordinator can cancel only transfers that actually own
  /// an adapter task while the durable `.deleting` mark makes a crash recoverable.
  public func markAllDeletingAsync() async throws -> [RSSDownloadRecord] {
    try await database.writeAsync { db in
      let rows = try RSSDownloadRecord.fetchAll(db, sql: "SELECT * FROM rssDownload ORDER BY id")
      for row in rows where row.state != .deleting {
        try db.execute(
          sql: "UPDATE rssDownload SET state = ?, holdReason = NULL, errorCode = NULL, updatedAt = ? WHERE id = ?",
          arguments: [DownloadState.deleting.rawValue, Date(), row.id!])
      }
      return rows
    }
  }

  /// A new credential applies to one device-owned feed. Atomically return only that feed's
  /// credential-held rows to the ordinary pending scheduler; Wi-Fi holds, other feeds, and ABS
  /// rows are outside this query by construction.
  public func releaseFeedCredentialHolds(feedId: Int64, now: Date = Date()) async throws -> Int {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE rssDownload
          SET state = ?, holdReason = NULL, errorCode = NULL, updatedAt = ?
          WHERE state = ? AND holdReason = ?
            AND episodeId IN (SELECT id FROM rssEpisode WHERE feedId = ?)
          """,
        arguments: [
          DownloadState.pending.rawValue, now, DownloadState.pausedAuth.rawValue,
          RSSDownloadHoldReason.feedCredentials.rawValue, feedId,
        ])
      return db.changesCount
    }
  }

  public func claimOrCreateAsync(
    episodeId: Int64, relativePath: String, expectedBytes: Int64?, origin: DownloadOrigin = .manual,
    decidedStamp: Date = Date(), now: Date = Date()
  ) async throws -> RSSDownloadRecord {
    try await database.writeAsync { db in
      try Self.claimOrCreate(
        episodeId: episodeId, relativePath: relativePath, expectedBytes: expectedBytes,
        origin: origin, decidedStamp: decidedStamp, now: now, in: db)
    }
  }

  @discardableResult
  public func claimOrCreateAsync(
    episodeId: Int64, origin: DownloadOrigin = .manual, decidedStamp: Date = Date(), now: Date = Date()
  ) async throws -> RSSDownloadRecord {
    guard let episode = try await database.readAsync({ db in try RSSEpisodeRecord.fetchOne(db, key: episodeId) }),
      let rowID = episode.id,
      try await database.readAsync({ db in try RSSFeedRecord.fetchOne(db, key: episode.feedId) }) != nil
    else { throw RSSDownloadStoreError.episodeNotFound(episodeId) }
    let url = URL(string: episode.enclosureURL) ?? URL(fileURLWithPath: "episode")
    let path = RSSFileStore.destinationRelativePath(
      feedId: episode.feedId, episodeRowId: rowID, enclosureURL: url,
      enclosureMimeType: episode.enclosureType)
    return try await claimOrCreateAsync(
      episodeId: episodeId, relativePath: path, expectedBytes: episode.declaredBytes,
      origin: origin, decidedStamp: decidedStamp, now: now)
  }

  public func transitionAsync(
    downloadId: Int64, to state: DownloadState, actualBytes: Int64? = nil,
    holdReason: RSSDownloadHoldReason? = nil, errorCode: DownloadErrorCategory? = nil,
    now: Date = Date()
  ) async throws -> RSSDownloadRecord {
    try await database.writeAsync { db in
      try Self.transition(
        downloadId: downloadId, to: state, actualBytes: actualBytes,
        holdReason: holdReason, errorCode: errorCode, now: now, in: db)
    }
  }

  /// Manual requests take ownership of an automatic RSS claim without creating a second row.
  @discardableResult
  public func promoteToManualAsync(downloadId: Int64, now: Date = Date()) async throws -> RSSDownloadRecord {
    try await database.writeAsync { db in
      guard var record = try RSSDownloadRecord.fetchOne(db, key: downloadId) else {
        throw RSSDownloadStoreError.downloadNotFound(downloadId)
      }
      if record.origin == .automatic {
        record.origin = .manual
        record.decidedStamp = now
        record.updatedAt = now
        try record.update(db)
      }
      return record
    }
  }

  /// Returns the existing claim when present.  A manual claim promotes an automatic claim, just
  /// like `DownloadStore.promoteToManual`; repeated claims never create a second episode row.
  @discardableResult
  public func claimOrCreate(
    episodeId: Int64, relativePath: String, expectedBytes: Int64?, origin: DownloadOrigin = .manual,
    decidedStamp: Date = Date(), now: Date = Date()
  ) throws -> RSSDownloadRecord {
    try database.write { db in
      try Self.claimOrCreate(
        episodeId: episodeId, relativePath: relativePath, expectedBytes: expectedBytes,
        origin: origin, decidedStamp: decidedStamp, now: now, in: db)
    }
  }

  /// Episode-derived claim used by download planning. The path is computed from persisted feed and
  /// episode identity, so a caller cannot accidentally place RSS audio in an ABS directory.
  @discardableResult
  public func claimOrCreate(
    episodeId: Int64, origin: DownloadOrigin = .manual, decidedStamp: Date = Date(), now: Date = Date()
  ) throws -> RSSDownloadRecord {
    guard let episode = try database.read({ db in try RSSEpisodeRecord.fetchOne(db, key: episodeId) }),
      let rowID = episode.id
    else { throw RSSDownloadStoreError.episodeNotFound(episodeId) }
    let feedId = episode.feedId
    guard try database.read({ db in try RSSFeedRecord.fetchOne(db, key: feedId) }) != nil else {
      throw RSSDownloadStoreError.episodeNotFound(episodeId)
    }
    let url = URL(string: episode.enclosureURL) ?? URL(fileURLWithPath: "episode")
    let path = RSSFileStore.destinationRelativePath(
      feedId: feedId, episodeRowId: rowID, enclosureURL: url, enclosureMimeType: episode.enclosureType)
    return try claimOrCreate(
      episodeId: episodeId, relativePath: path, expectedBytes: episode.declaredBytes,
      origin: origin, decidedStamp: decidedStamp, now: now)
  }

  public func transition(
    downloadId: Int64, to newState: DownloadState, actualBytes: Int64? = nil,
    holdReason: RSSDownloadHoldReason? = nil, errorCode: DownloadErrorCategory? = nil,
    now: Date = Date()
  ) throws -> RSSDownloadRecord {
    try database.write { db in
      try Self.transition(
        downloadId: downloadId, to: newState, actualBytes: actualBytes,
        holdReason: holdReason, errorCode: errorCode, now: now, in: db)
    }
  }

  public func updateProgress(
    downloadId: Int64, actualBytes: Int64, expectedBytes: Int64? = nil, now: Date = Date()
  ) throws -> RSSDownloadRecord {
    try database.write { db in
      try Self.updateProgress(
        downloadId: downloadId, actualBytes: actualBytes, expectedBytes: expectedBytes, now: now,
        in: db)
    }
  }

  public func updateProgressAsync(
    downloadId: Int64, actualBytes: Int64, expectedBytes: Int64? = nil, now: Date = Date()
  ) async throws -> RSSDownloadRecord {
    try await database.writeAsync { db in
      try Self.updateProgress(
        downloadId: downloadId, actualBytes: actualBytes, expectedBytes: expectedBytes, now: now,
        in: db)
    }
  }

  public func complete(downloadId: Int64, actualBytes: Int64, now: Date = Date()) throws -> RSSDownloadRecord {
    try database.write { db in
      try Self.complete(downloadId: downloadId, actualBytes: actualBytes, now: now, in: db)
    }
  }

  public func completeAsync(
    downloadId: Int64, actualBytes: Int64, now: Date = Date()
  ) async throws -> RSSDownloadRecord {
    try await database.writeAsync { db in
      try Self.complete(downloadId: downloadId, actualBytes: actualBytes, now: now, in: db)
    }
  }

  @discardableResult
  public func markDeleting(episodeId: Int64, now: Date = Date()) throws -> RSSDownloadRecord? {
    guard let record = try fetch(episodeId: episodeId) else { return nil }
    if record.state == .deleting { return record }
    return try transition(downloadId: record.id!, to: .deleting, now: now)
  }

  @discardableResult
  public func markDeleting(downloadId: Int64, now: Date = Date()) throws -> RSSDownloadRecord {
    guard let record = try fetch(downloadId: downloadId) else {
      throw RSSDownloadStoreError.downloadNotFound(downloadId)
    }
    if record.state == .deleting { return record }
    return try transition(downloadId: downloadId, to: .deleting, now: now)
  }

  @discardableResult
  public func markDeletingAsync(downloadId: Int64, now: Date = Date()) async throws -> RSSDownloadRecord {
    guard let record = try await fetchAsync(downloadId: downloadId) else {
      throw RSSDownloadStoreError.downloadNotFound(downloadId)
    }
    if record.state == .deleting { return record }
    return try await transitionAsync(downloadId: downloadId, to: .deleting, now: now)
  }

  @discardableResult
  public func markAllDeleting(now: Date = Date()) throws -> [RSSDownloadRecord] {
    let rows = try fetchAll()
    return try rows.map { row in
      guard let id = row.id else { return row }
      return try markDeleting(downloadId: id, now: now)
    }
  }

  public func finalizeDeletion(downloadId: Int64, now: Date = Date()) throws {
    try database.write { db in
      try Self.finalizeDeletion(downloadId: downloadId, now: now, in: db)
    }
  }

  public func finalizeDeletionAsync(downloadId: Int64, now: Date = Date()) async throws {
    try await database.writeAsync { db in
      try Self.finalizeDeletion(downloadId: downloadId, now: now, in: db)
    }
  }

  private static func fetch(episodeId: Int64, in db: Database) throws -> RSSDownloadRecord? {
    try RSSDownloadRecord.fetchOne(
      db, sql: "SELECT * FROM rssDownload WHERE episodeId = ?", arguments: [episodeId])
  }

  private static func claimOrCreate(
    episodeId: Int64, relativePath: String, expectedBytes: Int64?, origin: DownloadOrigin,
    decidedStamp: Date, now: Date, in db: Database
  ) throws -> RSSDownloadRecord {
    guard try RSSEpisodeRecord.fetchOne(db, key: episodeId) != nil else {
      throw RSSDownloadStoreError.episodeNotFound(episodeId)
    }
    if var existing = try fetch(episodeId: episodeId, in: db) {
      if origin == .manual, existing.origin == .automatic {
        existing.origin = .manual
        existing.decidedStamp = decidedStamp
        existing.updatedAt = now
        try existing.update(db)
      }
      if existing.origin == .automatic {
        try stampEpisodeForAutomaticDecision(
          episodeId: episodeId, decidedAt: decidedStamp, in: db)
      }
      return existing
    }
    var record = RSSDownloadRecord(
      episodeId: episodeId, relativePath: relativePath, expectedBytes: expectedBytes,
      origin: origin, decidedStamp: decidedStamp, createdAt: now, updatedAt: now)
    try record.insert(db)
    if origin == .automatic {
      try stampEpisodeForAutomaticDecision(episodeId: episodeId, decidedAt: decidedStamp, in: db)
    }
    return record
  }

  private static func stampEpisodeForAutomaticDecision(
    episodeId: Int64, decidedAt: Date, in db: Database
  ) throws {
    try db.execute(
      sql: "UPDATE rssEpisode SET autoDownloadDecidedAt = ? WHERE id = ?",
      arguments: [decidedAt, episodeId])
  }

  private static func transition(
    downloadId: Int64, to state: DownloadState, actualBytes: Int64?,
    holdReason: RSSDownloadHoldReason?, errorCode: DownloadErrorCategory?, now: Date,
    in db: Database
  ) throws -> RSSDownloadRecord {
    guard var record = try RSSDownloadRecord.fetchOne(db, key: downloadId) else {
      throw RSSDownloadStoreError.downloadNotFound(downloadId)
    }
    guard legalTransitions[record.state]?.contains(state) == true else {
      throw RSSDownloadStoreError.illegalTransition(from: record.state, to: state)
    }
    if let actualBytes { record.actualBytes = actualBytes }
    // Anything but `completed` means the file is not the one chapters were read from or measured.
    if state != .completed { try resetFileCaches(&record, in: db) }
    // Same rule as `DownloadStore.transition`: a deadline belongs to one failure, and this
    // `.failed -> .pending` edge is Try Again.
    record.autoRetryNotBefore = nil
    if record.state == .failed, state == .pending { record.autoRetryCount = 0 }
    record.state = state
    record.holdReason = state == .pending || state == .pausedAuth ? holdReason : nil
    record.errorCode = state == .failed || state == .pausedAuth ? errorCode : nil
    record.updatedAt = now
    try record.update(db)
    return record
  }

  /// `expectedBytes` is the size the live transfer reports, written only into a row that has none.
  /// A row's size normally comes from `<enclosure length>`, but many feeds (dynamically stitched
  /// ones especially) omit it or declare zero, which would show a spinner instead of a progress
  /// ring; the response's `Content-Length` is the only size they offer.
  ///
  /// Backfill-only: a declared size is kept, as the size text and ring draw from it and a
  /// redirect or ranged retry can report a different total mid-flight. An absent or non-positive
  /// transfer size (chunked, or `NSURLSessionTransferSizeUnknown`) never erases a recorded one.
  private static func updateProgress(
    downloadId: Int64, actualBytes: Int64, expectedBytes: Int64?, now: Date, in db: Database
  ) throws -> RSSDownloadRecord {
    guard let record = try RSSDownloadRecord.fetchOne(db, key: downloadId) else {
      throw RSSDownloadStoreError.downloadNotFound(downloadId)
    }
    guard record.state == .downloading else {
      throw RSSDownloadStoreError.illegalTransition(from: record.state, to: .downloading)
    }
    let backfilled: Int64? =
      (record.expectedBytes ?? 0) > 0
      ? nil
      : expectedBytes.flatMap { $0 > 0 ? $0 : nil }
    if let backfilled {
      try db.execute(
        sql: "UPDATE rssDownload SET actualBytes = ?, expectedBytes = ?, updatedAt = ? WHERE id = ?",
        arguments: [actualBytes, backfilled, now, downloadId])
    } else {
      try db.execute(
        sql: "UPDATE rssDownload SET actualBytes = ?, updatedAt = ? WHERE id = ?",
        arguments: [actualBytes, now, downloadId])
    }
    var updated = record
    updated.actualBytes = actualBytes
    if let backfilled { updated.expectedBytes = backfilled }
    updated.updatedAt = now
    return updated
  }

  private static func complete(
    downloadId: Int64, actualBytes: Int64, now: Date, in db: Database
  ) throws -> RSSDownloadRecord {
    guard var record = try RSSDownloadRecord.fetchOne(db, key: downloadId) else {
      throw RSSDownloadStoreError.downloadNotFound(downloadId)
    }
    guard record.state == .downloading else {
      throw RSSDownloadStoreError.illegalTransition(from: record.state, to: .completed)
    }
    guard actualBytes > 0 else { throw RSSDownloadStoreError.completionRequiresVerifiedFinalSize }
    guard record.relativePath.isEmpty == false else {
      throw RSSDownloadStoreError.completionRequiresRelativePath
    }
    record.actualBytes = actualBytes
    // A newly completed file is a new file, even if a stale marker survived.
    try resetFileCaches(&record, in: db)
    record.state = .completed
    record.holdReason = nil
    record.errorCode = nil
    record.autoRetryCount = 0
    record.autoRetryNotBefore = nil
    record.updatedAt = now
    try record.update(db)
    return record
  }

  /// Forgets what was read out of the file: the chapter marker and measured length live on the
  /// download row and the chapters in their own table; the caller saves `record`.
  private static func resetFileCaches(_ record: inout RSSDownloadRecord, in db: Database) throws {
    record.chaptersExtractedAt = nil
    record.measuredDurationSeconds = nil
    try RSSEpisodeChapterStore.invalidate(episodeId: record.episodeId, in: db)
  }

  /// Deleting an RSS row is an explicit decision by the user (or the automatic reaper), so the
  /// episode stays out of future automatic-download passes after the row disappears.
  private static func finalizeDeletion(downloadId: Int64, now: Date, in db: Database) throws {
    guard let record = try RSSDownloadRecord.fetchOne(db, key: downloadId) else {
      throw RSSDownloadStoreError.downloadNotFound(downloadId)
    }
    guard record.state == .deleting else {
      throw RSSDownloadStoreError.finalizeDeletionRequiresDeletingState(downloadId)
    }
    try db.execute(
      sql: """
        UPDATE rssEpisode
        SET autoDownloadDecidedAt = COALESCE(autoDownloadDecidedAt, ?)
        WHERE id = ?
        """,
      arguments: [now, record.episodeId])
    try RSSEpisodeChapterStore.invalidate(episodeId: record.episodeId, in: db)
    _ = try record.delete(db)
  }
}

/// Joined metadata needed to mint an enclosure transfer.  Keeping this query here prevents a
/// scheduler from accidentally joining a numeric ABS row to an RSS row with the same id.
public struct RSSDownloadTransferDetails: Sendable, Equatable {
  public let download: RSSDownloadRecord
  public let episode: RSSEpisodeRecord
  public let feed: RSSFeedRecord

  public init(download: RSSDownloadRecord, episode: RSSEpisodeRecord, feed: RSSFeedRecord) {
    self.download = download
    self.episode = episode
    self.feed = feed
  }
}

extension RSSDownloadStore {
  /// The device-owned half of `DownloadReading.observeEpisodeDownloadPresence`, keyed by the
  /// same `(show, episode)` identity a native episode carries everywhere else: the reserved
  /// `rss:<feedId>` item id and the episode's identity key. Summarised by the rule
  /// `DownloadStore.episodePresence` applies to ABS rows, so one surface can read both without
  /// knowing which table a row came from.
  static func episodePresence(_ db: Database) throws -> [EpisodeDownloadKey: ItemDownloadPresence] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT episode.feedId AS feedId,
               episode.identityKey AS identityKey,
               download.state AS state
        FROM rssDownload AS download
        JOIN rssEpisode AS episode ON episode.id = download.episodeId
        """)
    guard rows.isEmpty == false else { return [:] }

    var statesByKey: [EpisodeDownloadKey: [DownloadState]] = [:]
    for row in rows {
      let feedId: Int64 = row["feedId"]
      guard let itemID = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else { continue }
      let key = EpisodeDownloadKey(itemID: itemID, episodeID: row["identityKey"])
      let state: DownloadState = row["state"]
      statesByKey[key, default: []].append(state)
    }

    return statesByKey.reduce(into: [:]) { result, entry in
      let liveStates = entry.value.filter { $0 != .deleting }
      if liveStates.isEmpty {
        result[entry.key] = .deleting
      } else if liveStates.allSatisfy({ $0 == .completed }) {
        result[entry.key] = .completed
      } else {
        result[entry.key] = .partial
      }
    }
  }

  public func transferDetails(downloadId: Int64) throws -> RSSDownloadTransferDetails? {
    try database.read { db in
      try Self.transferDetails(db, where: "download.id = ?", arguments: [downloadId])
    }
  }

  public func transferDetailsAsync(downloadId: Int64) async throws -> RSSDownloadTransferDetails? {
    try await database.readAsync { db in
      try Self.transferDetails(db, where: "download.id = ?", arguments: [downloadId])
    }
  }

  private static func transferDetails(
    _ db: Database, where predicate: String, arguments: StatementArguments
  ) throws -> RSSDownloadTransferDetails? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT download.id AS downloadID, download.episodeId AS episodeID
          FROM rssDownload AS download
          JOIN rssEpisode AS episode ON episode.id = download.episodeId
          JOIN rssFeed AS feed ON feed.id = episode.feedId
          WHERE \(predicate)
          """,
        arguments: arguments)
    else { return nil }
    // Prefixes avoid Row key collisions (all three tables have id/state-like columns).
    guard
      let download = try RSSDownloadRecord.fetchOne(
        db, sql: "SELECT * FROM rssDownload WHERE id = ?", arguments: [row["downloadID"] as Int64]),
      let episode = try RSSEpisodeRecord.fetchOne(db, key: row["episodeID"] as Int64),
      let feed = try RSSFeedRecord.fetchOne(db, key: episode.feedId)
    else { return nil }
    return RSSDownloadTransferDetails(download: download, episode: episode, feed: feed)
  }
}
