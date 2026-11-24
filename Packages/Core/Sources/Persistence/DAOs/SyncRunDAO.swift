import Foundation
import GRDB
import os

/// Durable bookkeeping for a library traversal. Every GRDB-touching primitive SyncEngine needs
/// (generation allocation, the run/page rows, two-pass deletion inference) lives here, because
/// SyncEngine may not import GRDB (ARCHITECTURE.md §1). SyncEngine maps wire DTOs into the plain
/// `ItemRecord` values below and calls through this DAO.
public struct SyncRunDAO: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// A single monotonically increasing counter per account, shared across every library's runs.
  /// Item-generation comparisons are always scoped to one library's rows, so sharing the counter
  /// is simpler than a per-library one and changes no deletion-inference outcome.
  public func nextGeneration(accountId: Int64) throws -> Int {
    try database.read { db in try Self.nextGeneration(in: db, accountId: accountId) }
  }

  public func nextGenerationAsync(accountId: Int64) async throws -> Int {
    try await database.readAsync { db in try Self.nextGeneration(in: db, accountId: accountId) }
  }

  private static func nextGeneration(in db: Database, accountId: Int64) throws -> Int {
    let maxGeneration =
      try Int.fetchOne(
        db, sql: "SELECT MAX(generation) FROM syncRun WHERE accountId = ?", arguments: [accountId])
    return (maxGeneration ?? 0) + 1
  }

  @discardableResult
  public func startRun(
    accountId: Int64,
    libraryId: Int64?,
    reason: String,
    generation: Int,
    sortRequested: String?,
    startedAt: Date
  ) throws -> SyncRunRecord {
    try database.write { db in
      try Self.startRun(
        in: db,
        accountId: accountId,
        libraryId: libraryId,
        reason: reason,
        generation: generation,
        sortRequested: sortRequested,
        startedAt: startedAt)
    }
  }

  @discardableResult
  public func startRunAsync(
    accountId: Int64,
    libraryId: Int64?,
    reason: String,
    generation: Int,
    sortRequested: String?,
    startedAt: Date
  ) async throws -> SyncRunRecord {
    try await database.writeAsync { db in
      try Self.startRun(
        in: db,
        accountId: accountId,
        libraryId: libraryId,
        reason: reason,
        generation: generation,
        sortRequested: sortRequested,
        startedAt: startedAt
      )
    }
  }

  private static func startRun(
    in db: Database,
    accountId: Int64,
    libraryId: Int64?,
    reason: String,
    generation: Int,
    sortRequested: String?,
    startedAt: Date
  ) throws -> SyncRunRecord {
    var record = SyncRunRecord(
      accountId: accountId,
      libraryId: libraryId,
      reason: reason,
      generation: generation,
      startedAt: startedAt,
      state: .running,
      sortRequested: sortRequested
    )
    try record.insert(db)
    return record
  }

  /// A `running` row means "this process is traversing right now". A process that dies
  /// mid-traversal (killed while suspended, crashed, stopped from Xcode) leaves it behind, and
  /// every later reader (`LibrarySyncStatus.isRunning`, the podcast catalogue gate) would believe
  /// a traversal is permanently in flight. SyncEngine's single-flight guard means no run it
  /// started is still open when a refresh begins, so any `running` row seen then is abandoned and
  /// settles as `.incomplete`, never `.completed`, which would license deletion inference for
  /// pages never fetched.
  @discardableResult
  public func reapAbandonedRunsAsync(accountId: Int64, at date: Date) async throws -> Int {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE syncRun
          SET state = ?, completedAt = ?, errorCategory = ?
          WHERE accountId = ? AND state = ?
          """,
        arguments: [SyncRunState.incomplete, date, "abandoned", accountId, SyncRunState.running])
      return db.changesCount
    }
  }

  public func fetch(runId: Int64) throws -> SyncRunRecord? {
    try database.read { db in try SyncRunRecord.fetchOne(db, key: runId) }
  }

  public func fetchAll(accountId: Int64) throws -> [SyncRunRecord] {
    try database.read { db in
      try SyncRunRecord.filter(Column("accountId") == accountId).fetchAll(db)
    }
  }

  public func fetchPages(runId: Int64) throws -> [SyncPageRecord] {
    try database.read { db in
      try SyncPageRecord
        .filter(Column("syncRunId") == runId)
        .order(Column("pageNumber"))
        .fetchAll(db)
    }
  }

  public func finish(
    runId: Int64,
    state: SyncRunState,
    completedAt: Date,
    errorCategory: String?
  ) throws {
    try database.write { db in
      try Self.finish(
        in: db,
        runId: runId,
        state: state,
        completedAt: completedAt,
        errorCategory: errorCategory)
    }
  }

  public func finishAsync(
    runId: Int64,
    state: SyncRunState,
    completedAt: Date,
    errorCategory: String?
  ) async throws {
    try await database.writeAsync { db in
      try Self.finish(
        in: db,
        runId: runId,
        state: state,
        completedAt: completedAt,
        errorCategory: errorCategory)
    }
  }

  private static func finish(
    in db: Database,
    runId: Int64,
    state: SyncRunState,
    completedAt: Date,
    errorCategory: String?
  ) throws {
    guard var record = try SyncRunRecord.fetchOne(db, key: runId) else { return }
    record.state = state
    record.completedAt = completedAt
    record.errorCategory = errorCategory
    try record.update(db)
  }

  /// One page's item upserts plus its checkpoint row, applied atomically: a crash between two
  /// `applyPage` calls resumes or restarts cleanly, never half-applies a page. A row seen again
  /// is revived (`softDeleted` cleared) even if an earlier run had tombstoned it. Returns the
  /// saved records with their resolved local row ids.
  @discardableResult
  public func applyPage(
    runId: Int64,
    accountId: Int64,
    libraryId: Int64,
    generation: Int,
    items: [ItemRecord],
    pageNumber: Int,
    fetchedAt: Date,
    resultCategory: String?
  ) throws -> [ItemRecord] {
    try database.write { db in
      try Self.applyPage(
        in: db,
        runId: runId,
        accountId: accountId,
        libraryId: libraryId,
        generation: generation,
        items: items,
        pageNumber: pageNumber,
        fetchedAt: fetchedAt,
        resultCategory: resultCategory)
    }
  }

  @discardableResult
  public func applyPageAsync(
    runId: Int64,
    accountId: Int64,
    libraryId: Int64,
    generation: Int,
    items: [ItemRecord],
    pageNumber: Int,
    fetchedAt: Date,
    resultCategory: String?
  ) async throws -> [ItemRecord] {
    try await database.writeAsync { db in
      try Self.applyPage(
        in: db,
        runId: runId,
        accountId: accountId,
        libraryId: libraryId,
        generation: generation,
        items: items,
        pageNumber: pageNumber,
        fetchedAt: fetchedAt,
        resultCategory: resultCategory)
    }
  }

  #if PERF_INVESTIGATION
    /// Diagnostic-only: reports how many rows a traversal wrote versus how many it found
    /// identical and skipped, and which columns the written ones differed in. The elision itself
    /// is production behaviour; this only makes it observable.
    private static let measuresItemElision = ProcessInfo.processInfo.arguments.contains(
      "-perf-measure-item-elision")
    private static let elisionLog = Logger(
      subsystem: "com.remoteconcern.whirr", category: "perf.elision")
  #endif

  private static func applyPage(
    in db: Database,
    runId: Int64,
    accountId: Int64,
    libraryId: Int64,
    generation: Int,
    items: [ItemRecord],
    pageNumber: Int,
    fetchedAt: Date,
    resultCategory: String?
  ) throws -> [ItemRecord] {
    var saved: [ItemRecord] = []
    #if PERF_INVESTIGATION
      var elidedCount = 0
      var writtenCount = 0
      var insertedCount = 0
      var differingColumnCounts: [String: Int] = [:]
    #endif
    for var item in items {
      item.accountId = accountId
      item.libraryId = libraryId
      item.softDeleted = false
      if let existing =
        try ItemRecord
        .filter(Column("libraryId") == libraryId)
        .filter(Column("serverItemId") == item.serverItemId)
        .fetchOne(db)
      {
        item.id = existing.id
        item.preserveEbookIdentity(from: existing)
        // The seen-set lives in its own table so an identical re-visited row is not written and
        // the page's commit misses the region any `item` observation tracks. Compare as database
        // values: `Equatable` reports phantom changes, since a wire-decoded `Date` and the same
        // `Date` after a storage round-trip differ in the last `Double` bits but encode to the
        // identical column string.
        let changedColumns = try item.databaseChanges(from: existing)
        if changedColumns.isEmpty == false {
          try item.save(db)
        }
        #if PERF_INVESTIGATION
          if changedColumns.isEmpty {
            elidedCount += 1
          } else {
            writtenCount += 1
            for column in changedColumns.keys { differingColumnCounts[column, default: 0] += 1 }
          }
        #endif
      } else {
        try item.save(db)
        #if PERF_INVESTIGATION
          insertedCount += 1
        #endif
      }
      if let itemId = item.id {
        try ItemSeenRecord(itemId: itemId, generation: generation).save(db)
      }
      saved.append(item)
    }
    #if PERF_INVESTIGATION
      if Self.measuresItemElision {
        let columns = differingColumnCounts.sorted { $0.value > $1.value }
          .map { "\($0.key):\($0.value)" }.joined(separator: ",")
        Self.elisionLog.log(
          "page libraryId=\(libraryId, privacy: .public) page=\(pageNumber, privacy: .public) elided=\(elidedCount, privacy: .public) written=\(writtenCount, privacy: .public) inserted=\(insertedCount, privacy: .public) columns=[\(columns, privacy: .public)]"
        )
      }
    #endif

    var page =
      try SyncPageRecord
      .filter(Column("syncRunId") == runId)
      .filter(Column("pageNumber") == pageNumber)
      .fetchOne(db)
      ?? SyncPageRecord(
        accountId: accountId,
        syncRunId: runId,
        pageNumber: pageNumber,
        itemCount: items.count,
        fetchedAt: fetchedAt,
        resultCategory: resultCategory
      )
    page.itemCount = items.count
    page.fetchedAt = fetchedAt
    page.resultCategory = resultCategory
    try page.save(db)

    return saved
  }

  public struct DeletionSummary: Sendable, Equatable {
    public let softDeletedCount: Int
    public let hardDeletedCount: Int
    public let tombstonedCount: Int
  }

  /// Two-pass deletion inference, only after a fully successful traversal (an incomplete or
  /// aborted run must never call this). Pass 1: rows unseen this generation and not yet
  /// tombstoned become soft-deleted. Pass 2: rows tombstoned by an earlier completed generation
  /// and still unseen are hard-deleted, unless referenced by progress/outbox/session/download
  /// state, in which case they become minimal tombstones (metadata blanked, row/flags kept).
  @discardableResult
  public func inferDeletions(
    libraryId: Int64,
    generation: Int
  ) throws -> DeletionSummary {
    try database.write { db in
      try Self.inferDeletions(
        in: db, libraryId: libraryId, generation: generation)
    }
  }

  @discardableResult
  public func inferDeletionsAsync(
    libraryId: Int64,
    generation: Int
  ) async throws -> DeletionSummary {
    try await database.writeAsync { db in
      try Self.inferDeletions(
        in: db, libraryId: libraryId, generation: generation)
    }
  }

  /// Items in this library that the generation's traversal did not visit.
  ///
  /// The join must be a LEFT JOIN: rows reaching `item` outside a traversal (search's
  /// non-destructive upsert, podcast refresh) have no `itemSeen` row, and an inner join would
  /// exclude them from deletion inference forever. A missing seen row means "never seen", older
  /// than any real generation, and must qualify.
  private static func unseenItems(
    in db: Database,
    libraryId: Int64,
    generation: Int,
    softDeleted: Bool
  ) throws -> [ItemRecord] {
    try ItemRecord.fetchAll(
      db,
      sql: """
        SELECT item.* FROM item
        LEFT JOIN itemSeen ON itemSeen.itemId = item.id
        WHERE item.libraryId = ?
          AND item.softDeleted = ?
          AND (itemSeen.generation IS NULL OR itemSeen.generation < ?)
        """,
      arguments: [libraryId, softDeleted, generation])
  }

  private static func inferDeletions(
    in db: Database,
    libraryId: Int64,
    generation: Int
  ) throws -> DeletionSummary {
    let toSoftDelete = try Self.unseenItems(
      in: db, libraryId: libraryId, generation: generation, softDeleted: false)
    for var item in toSoftDelete {
      item.softDeleted = true
      try item.update(db)
    }
    let softDeletedIds = Set(toSoftDelete.compactMap(\.id))
    let hardDeleteCandidates =
      try Self.unseenItems(
        in: db, libraryId: libraryId, generation: generation, softDeleted: true
      )
      .filter { item in item.id.map { softDeletedIds.contains($0) == false } ?? false }

    var hardDeletedCount = 0
    var tombstonedCount = 0
    for item in hardDeleteCandidates {
      guard let itemId = item.id else { continue }
      if try Self.isReferenced(db, itemId: itemId) {
        var tombstone = item
        tombstone.title = ""
        tombstone.sortTitle = ""
        tombstone.author = nil
        tombstone.durationSeconds = nil
        try tombstone.update(db)
        tombstonedCount += 1
      } else {
        _ = try item.delete(db)
        hardDeletedCount += 1
      }
    }

    return DeletionSummary(
      softDeletedCount: toSoftDelete.count,
      hardDeletedCount: hardDeletedCount,
      tombstonedCount: tombstonedCount
    )
  }

  /// A pending `progress`-kind outbox row carries the item's real `serverItemId` as its
  /// `entityKey`: `OutboxDrainer.sendProgress` sends it straight through as the wire
  /// `libraryItemID`, and `PlaybackSessionStore.markSessionGone`'s preserved-position row is
  /// written the same way (API-CONVENTIONS rule 11). Resolve `itemId`'s own `serverItemId` before
  /// matching. Mirrors `MediaProgressDAO.hasUnacknowledgedLocalOperation`.
  private static func isReferenced(_ db: Database, itemId: Int64) throws -> Bool {
    if try MediaProgressRecord.filter(Column("itemId") == itemId).fetchCount(db) > 0 { return true }
    if let serverItemId = try ItemRecord.fetchOne(db, key: itemId)?.serverItemId,
      (try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*)
          FROM outboxOperation
          WHERE entityKey = ?
            AND (
              deadLetterReason IS NULL
              OR deadLetterReason != ?
              OR NOT EXISTS (SELECT 1 FROM itemQuarantine WHERE itemId = ?)
            )
          """,
        arguments: [serverItemId, OutboxStore.quarantinedItemDeadLetterReason, itemId]) ?? 0) > 0
    {
      return true
    }
    if try PlaybackSessionRecord.filter(Column("itemId") == itemId).fetchCount(db) > 0 { return true }
    if try DownloadRecord.filter(Column("itemId") == itemId).fetchCount(db) > 0 { return true }
    // `listeningQueueEntry` is the universal queue, so a directly-queued audiobook item
    // (`itemId` on the row itself, no episode) is a reference in its own right, not only a
    // queued episode of a podcast show.
    if try ListeningQueueEntryRecord.filter(Column("itemId") == itemId).fetchCount(db) > 0 {
      return true
    }
    // Saved for Later episode rows carry the parent `itemId`, so no episode join is needed.
    if try SavedShelfEntryRecord.filter(Column("itemId") == itemId).fetchCount(db) > 0 {
      return true
    }
    if try Int.fetchOne(
      db,
      sql: """
        SELECT 1
        FROM listeningQueueEntry AS queue
        JOIN podcastEpisode AS episode ON episode.id = queue.podcastEpisodeId
        WHERE episode.itemId = ?
        LIMIT 1
        """,
      arguments: [itemId]) != nil
    {
      return true
    }
    return false
  }
}
