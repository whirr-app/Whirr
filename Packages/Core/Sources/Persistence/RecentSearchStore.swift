import Foundation
import GRDB

/// `RecentSearchStoring` over the `recentSearch` table. Persisted per account rather than in
/// defaults, so recents cascade away with the account like every other account-owned table. A thin
/// wrapper around `AppDatabase` with no caller-visible GRDB types.
public struct RecentSearchStore: RecentSearchStoring, Sendable {
  private let database: AppDatabase
  private let accountId: Int64
  private let cap: Int
  private let minimumQueryLength: Int
  private let now: @Sendable () -> Date

  /// `cap` bounds the per-account list; the oldest (`lastUsedAt`) is evicted first on every write.
  /// `minimumQueryLength` mirrors `AppModel.SearchModel`'s default of 2, since a query too short to
  /// have produced a real search is not worth remembering. It is a separate constant because
  /// Persistence may not import AppModel. Callers should only `record` a settled, already-searched
  /// query, so this is a defensive floor rather than the primary gate.
  public init(
    database: AppDatabase,
    accountId: Int64,
    cap: Int = 10,
    minimumQueryLength: Int = 2,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    self.accountId = accountId
    self.cap = cap
    self.minimumQueryLength = minimumQueryLength
    self.now = now
  }

  public func record(query: String) async throws {
    let displayQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard displayQuery.count >= minimumQueryLength else { return }
    let normalizedQuery = SearchQueryNormalizer.normalize(displayQuery)
    guard normalizedQuery.isEmpty == false else { return }

    try await database.writeAsync { db in
      // Upsert on the `(accountId, normalizedQuery)` unique index: re-recording an existing
      // entry refreshes its display text and moves it to the front via `lastUsedAt`, rather than
      // reading first and racing a concurrent recorder.
      try db.execute(
        sql: """
          INSERT INTO recentSearch (accountId, normalizedQuery, displayQuery, lastUsedAt)
          VALUES (?, ?, ?, ?)
          ON CONFLICT(accountId, normalizedQuery) DO UPDATE SET
            displayQuery = excluded.displayQuery,
            lastUsedAt = excluded.lastUsedAt
          """,
        arguments: [accountId, normalizedQuery, displayQuery, now()])
      try Self.evictBeyondCap(db, accountId: accountId, cap: cap)
    }
  }

  public func clear(query: String) async throws {
    let normalizedQuery = SearchQueryNormalizer.normalize(query)
    try await database.writeAsync { db in
      _ =
        try RecentSearchRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("normalizedQuery") == normalizedQuery)
        .deleteAll(db)
    }
  }

  public func clearAll() async throws {
    try await database.writeAsync { db in
      _ = try RecentSearchRecord.filter(Column("accountId") == accountId).deleteAll(db)
    }
  }

  public func observeRecent() -> AsyncStream<[RecentSearchQuery]> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      try Self.records(db, accountId: accountId)
    }
  }

  /// One-shot read for tests and callers where an `AsyncStream` would be overkill.
  public func fetchRecent() async -> [RecentSearchQuery] {
    (try? await database.readAsync { db in try Self.records(db, accountId: accountId) }) ?? []
  }

  private static func records(_ db: Database, accountId: Int64) throws -> [RecentSearchQuery] {
    try RecentSearchRecord
      .filter(Column("accountId") == accountId)
      .order(Column("lastUsedAt").desc, Column("id").desc)
      .fetchAll(db)
      .map {
        RecentSearchQuery(
          normalizedQuery: $0.normalizedQuery, displayQuery: $0.displayQuery,
          lastUsedAt: $0.lastUsedAt)
      }
  }

  private static func evictBeyondCap(_ db: Database, accountId: Int64, cap: Int) throws {
    let count = try RecentSearchRecord.filter(Column("accountId") == accountId).fetchCount(db)
    let overflow = count - cap
    guard overflow > 0 else { return }
    let staleIds =
      try RecentSearchRecord
      .filter(Column("accountId") == accountId)
      .order(Column("lastUsedAt"), Column("id"))
      .limit(overflow)
      .fetchAll(db)
      .compactMap(\.id)
    try RecentSearchRecord.deleteAll(db, keys: staleIds)
  }
}
