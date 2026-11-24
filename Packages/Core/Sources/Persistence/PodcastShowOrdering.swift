import GRDB

/// The two orderings Your Shows can be in. Stored as its raw value in `podcastShowOrder.mode`, and
/// only ever written as `custom`: an absent row, like an unrecognised one, means alphabetical.
public enum PodcastShowSortMode: String, Sendable, Equatable {
  case alphabetical
  case custom
}

/// One effective, already-ordered view of the account's live podcast shows plus the mode that
/// produced it. The sequence is the durable truth: nothing above Persistence re-sorts it.
public struct PodcastShowsSnapshot: Sendable, Equatable {
  public let mode: PodcastShowSortMode
  public let shows: [ItemSummary]

  public init(mode: PodcastShowSortMode, shows: [ItemSummary]) {
    self.mode = mode
    self.shows = shows
  }
}

public enum PodcastShowOrderingError: Error, Equatable, Sendable {
  case duplicateItemID(String)
  /// The id is not a live podcast belonging to this account: unknown, soft-deleted, a book, or
  /// another account's item. One case because the caller's remedy is identical for all four, and
  /// distinguishing them would leak whether another account holds a given id.
  case unknownItemID(String)
  /// The replacement omitted these live podcast ids (sorted). A custom order is one total order
  /// over everything currently visible, so a partial replacement is rejected rather than padded.
  case missingItemIDs([String])
}

/// Failure-injection points inside the replacement/reset transactions, mirroring
/// `ListeningQueueMutationCheckpoint`: they exist so tests can prove that a crash between the
/// delete and the reinsert leaves no partially renumbered order behind.
enum PodcastShowOrderMutationCheckpoint: Sendable, Equatable {
  case afterDeletingPositions
  case afterInsertingPositions
}

/// The whole ordering boundary AppModel sees. `itemIDs` are server item ids
/// (`ItemSummary.serverItemId`), the id currency above Persistence. Internal row ids never cross
/// this line.
public protocol PodcastShowOrdering: Sendable {
  func observeShows() -> AsyncStream<PodcastShowsSnapshot>
  func replaceCustomOrder(itemIDs: [String]) async throws
  func resetToAlphabetical() async throws
}

/// Incremental-composition default: no database, no fabricated order.
public struct NoOpPodcastShowOrdering: PodcastShowOrdering, Sendable {
  public init() {}
  public func observeShows() -> AsyncStream<PodcastShowsSnapshot> { AsyncStream { $0.finish() } }
  public func replaceCustomOrder(itemIDs: [String]) async throws {}
  public func resetToAlphabetical() async throws {}
}

/// The account-scoped ordering store. Purely local: every mutation is one transaction against
/// `podcastShowOrder`/`podcastShowOrderEntry`, and none of them enqueues an outbox operation or
/// touches the server. A custom order is a device arrangement, not library data.
public struct DefaultPodcastShowOrdering: PodcastShowOrdering, Sendable {
  private let database: AppDatabase
  private let accountId: Int64
  private let mutationCheckpoint: @Sendable (PodcastShowOrderMutationCheckpoint) throws -> Void

  public init(database: AppDatabase, accountId: Int64) {
    self.database = database
    self.accountId = accountId
    self.mutationCheckpoint = { _ in }
  }

  init(
    database: AppDatabase,
    accountId: Int64,
    mutationCheckpoint: @escaping @Sendable (PodcastShowOrderMutationCheckpoint) throws -> Void
  ) {
    self.database = database
    self.accountId = accountId
    self.mutationCheckpoint = mutationCheckpoint
  }

  public func observeShows() -> AsyncStream<PodcastShowsSnapshot> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.snapshot(db, accountId: self.accountId)
    }
  }

  func fetchShows() async -> PodcastShowsSnapshot {
    (try? await database.readAsync { db in
      try Self.snapshot(db, accountId: self.accountId)
    }) ?? PodcastShowsSnapshot(mode: .alphabetical, shows: [])
  }

  /// Validation runs to completion before the first delete, so a rejected replacement leaves the
  /// existing order byte-for-byte intact rather than relying on the rollback alone.
  public func replaceCustomOrder(itemIDs: [String]) async throws {
    try await database.writeAsync { db in
      let live = try Self.liveShowRowIds(db, accountId: self.accountId)
      var named: Set<String> = []
      var rowIds: [Int64] = []
      for itemID in itemIDs {
        guard named.insert(itemID).inserted else {
          throw PodcastShowOrderingError.duplicateItemID(itemID)
        }
        guard let rowId = live[itemID] else {
          throw PodcastShowOrderingError.unknownItemID(itemID)
        }
        rowIds.append(rowId)
      }
      let missing = Set(live.keys).subtracting(named)
      guard missing.isEmpty else {
        throw PodcastShowOrderingError.missingItemIDs(missing.sorted())
      }

      // Deleting every account row before reinserting a dense zero-based sequence is what keeps
      // the unique `(accountId, position)` index satisfiable without temporary renumbering.
      try Self.deletePositions(db, accountId: self.accountId)
      try self.mutationCheckpoint(.afterDeletingPositions)
      for (position, rowId) in rowIds.enumerated() {
        var entry = PodcastShowOrderEntryRecord(
          accountId: self.accountId, itemId: rowId, position: position)
        try entry.insert(db)
      }
      try self.mutationCheckpoint(.afterInsertingPositions)
      try PodcastShowOrderRecord(
        accountId: self.accountId, mode: PodcastShowSortMode.custom.rawValue
      ).save(db)
    }
  }

  public func resetToAlphabetical() async throws {
    try await database.writeAsync { db in
      try Self.deletePositions(db, accountId: self.accountId)
      try self.mutationCheckpoint(.afterDeletingPositions)
      _ =
        try PodcastShowOrderRecord
        .filter(Column("accountId") == self.accountId)
        .deleteAll(db)
    }
  }

  private static func snapshot(_ db: Database, accountId: Int64) throws -> PodcastShowsSnapshot {
    let mode = try self.mode(db, accountId: accountId)
    return PodcastShowsSnapshot(
      mode: mode, shows: try shows(db, accountId: accountId, mode: mode))
  }

  /// Reads the row inside the tracked fetch so the observation reacts to mode changes, and fails
  /// closed to alphabetical for an unrecognised value, so corruption never hides shows.
  static func mode(_ db: Database, accountId: Int64) throws -> PodcastShowSortMode {
    guard
      let record =
        try PodcastShowOrderRecord
        .filter(Column("accountId") == accountId)
        .fetchOne(db),
      let mode = PodcastShowSortMode(rawValue: record.mode)
    else { return .alphabetical }
    return mode
  }

  /// The one definition of each mode's order, shared by the whole-list observation and the paged
  /// read. `position IS NULL` sorts last, so unpositioned shows form an alphabetical tail after
  /// the positioned ones, with `serverItemId` as the final deterministic tie.
  static func keyset(mode: PodcastShowSortMode) -> Keyset {
    let alphabetical = [KeysetTerm(expression: "item.sortTitle"), KeysetTerm(expression: "item.serverItemId")]
    switch mode {
    case .alphabetical:
      return Keyset(scope: "server-shows:alphabetical", terms: alphabetical)
    case .custom:
      return Keyset(
        scope: "server-shows:custom",
        terms: [
          KeysetTerm(expression: "entry.position IS NULL"),
          KeysetTerm(expression: "COALESCE(entry.position, 0)"),
        ] + alphabetical)
    }
  }

  /// The live shows of one account, taking the account id as its single argument. The left join
  /// is mandatory: an inner join would hide every show synced since the last reorder.
  static let liveShowsSQL = """
    FROM item
    JOIN library
      ON library.id = item.libraryId
      AND library.accountId = item.accountId
    LEFT JOIN podcastShowOrderEntry AS entry
      ON entry.itemId = item.id AND entry.accountId = item.accountId
    WHERE item.accountId = ?
      AND \(ItemVisibilityPredicate.sql)
      AND \(ItemCategoryPredicate.sql(.podcast))
      AND \(PodcastCatalogueVisibilityPredicate.sql)
    """

  private static func shows(
    _ db: Database, accountId: Int64, mode: PodcastShowSortMode
  ) throws -> [ItemSummary] {
    try ItemRecord.fetchAll(
      db,
      sql: """
        SELECT item.*
        \(liveShowsSQL)
        \(keyset(mode: mode).ordering)
        """,
      arguments: [accountId]
    )
    .map(DefaultLibraryReading.makeSummary)
  }

  private static func liveShowRowIds(_ db: Database, accountId: Int64) throws -> [String: Int64] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT item.serverItemId AS serverItemId, item.id AS id
        FROM item
        JOIN library
          ON library.id = item.libraryId
          AND library.accountId = item.accountId
        WHERE item.accountId = ?
          AND \(ItemVisibilityPredicate.sql)
          AND \(ItemCategoryPredicate.sql(.podcast))
          AND \(PodcastCatalogueVisibilityPredicate.sql)
        """,
      arguments: [accountId])
    return Dictionary(
      rows.map { ($0["serverItemId"] as String, $0["id"] as Int64) },
      uniquingKeysWith: { first, _ in first })
  }

  private static func deletePositions(_ db: Database, accountId: Int64) throws {
    _ =
      try PodcastShowOrderEntryRecord
      .filter(Column("accountId") == accountId)
      .deleteAll(db)
  }

}
