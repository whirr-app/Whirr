import Foundation
import GRDB
import Persistence

/// The committed baseline store for the released schema, plus the tool that regenerates it.
///
/// The released schema is the whole registered migration list: `v1`, `v2` (`healItemHomeColumns`)
/// and `v3` (`createPlaybackBookmark` heal). GRDB never revisits an applied migration, so none of
/// those three may be edited in place. Every later change appends a new numbered migration and is
/// tested from this fixture.
///
/// Every account-owned table carries at least one row, pointing at each other through the real
/// foreign keys, so `PRAGMA foreign_key_check` and the account-removal sweep have something to
/// prove. Every value is synthetic, and
/// `ReleasedSchemaMigrationTests.committedFixtureContainsNoRealIdentifiers` enforces that none
/// looks like a URL or a token.
///
/// Regenerate the expected schema checksum after appending a migration with:
///
///     REGENERATE_RELEASED_SCHEMA_FIXTURE=1 swift test --filter RegenerateReleasedSchemaFixture
///
/// which rewrites only the expected-schema file. The committed SQLite store stays the immutable
/// v1-v3 baseline; a freshly migrated store would erase the historical path under test.
public enum ReleasedSchemaFixture {

  public static let storeResourceName = "released-schema-baseline"
  public static let storeResourceExtension = "sqlite"
  public static let schemaResourceName = "released-schema-baseline"
  public static let schemaResourceExtension = "schema"

  /// The frozen migration identifiers. A fixture carrying anything else is not the released
  /// baseline.
  public static let frozenMigrations = ["v1", "v2", "v3"]

  /// Synthetic primary keys, so assertions can address a specific row without re-querying by
  /// content. `AUTOINCREMENT` columns accept explicit ids.
  public enum RowID {
    public static let account: Int64 = 1
    public static let secondAccount: Int64 = 2
    public static let library: Int64 = 1
    public static let bookItem: Int64 = 1
    public static let podcastItem: Int64 = 2
    public static let secondAccountItem: Int64 = 3
    public static let episode: Int64 = 1
    public static let itemProgress: Int64 = 1
    public static let episodeProgress: Int64 = 2
    public static let session: Int64 = 1
    public static let syncRun: Int64 = 1
  }

  /// Every table the fixture populates, with the number of rows it carries. The migration test
  /// asserts each count survives a migrator run unchanged.
  public static let expectedRowCounts: [String: Int] = [
    "account": 2,
    "library": 2,
    "item": 3,
    "podcastEpisode": 1,
    "mediaProgress": 3,
    "progressConflict": 1,
    "playbackSession": 2,
    "outboxOperation": 2,
    "download": 2,
    "syncRun": 1,
    "syncPage": 2,
    "diagnosticsEvent": 1,
    "observedServerTime": 1,
    "listeningHistoryEntry": 1,
    "playbackBookmark": 2,
    "accountRemovalJournal": 1,
  ]

  /// `accountRemovalJournal` carries no `accountId` foreign key: it records a removal in
  /// progress, so it must outlive the account row it describes. Every other populated table is
  /// account-owned and must be swept to zero.
  public static let tablesSurvivingAccountRemoval = ["accountRemovalJournal"]

  // MARK: - Loading the committed fixture

  public enum FixtureError: Error, Equatable {
    case resourceMissing(String)
  }

  /// Copies the committed store into `directory` and returns the copy's URL. The fixture is opened
  /// read-write by the migration tests, so they must never touch the bundled bytes.
  public static func copyOfCommittedStore(into directory: URL) throws -> URL {
    guard
      let source = Bundle.module.url(
        forResource: storeResourceName, withExtension: storeResourceExtension)
    else {
      throw FixtureError.resourceMissing("\(storeResourceName).\(storeResourceExtension)")
    }
    let destination = directory.appendingPathComponent(
      "\(storeResourceName).\(storeResourceExtension)")
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  /// The committed store's raw bytes, for the privacy canary.
  public static func committedStoreBytes() throws -> Data {
    guard
      let url = Bundle.module.url(
        forResource: storeResourceName, withExtension: storeResourceExtension)
    else {
      throw FixtureError.resourceMissing("\(storeResourceName).\(storeResourceExtension)")
    }
    return try Data(contentsOf: url)
  }

  /// The committed expected-schema text that the checksum test compares against.
  public static func committedSchemaText() throws -> String {
    guard
      let url = Bundle.module.url(
        forResource: schemaResourceName, withExtension: schemaResourceExtension)
    else {
      throw FixtureError.resourceMissing("\(schemaResourceName).\(schemaResourceExtension)")
    }
    return try String(contentsOf: url, encoding: .utf8)
  }

  // MARK: - Reading a store without migrating it

  /// Opens `url` read-only, so nothing runs the migrator, and reports what the file itself records
  /// as applied. Opening a store through `AppDatabase` heals it, so "what the committed bytes
  /// carry" and "what an opened copy reports" are different questions.
  public static func appliedMigrations(inStoreAt url: URL) throws -> [String] {
    try readingWithoutMigrating(url) { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
  }

  /// `normalizedSchema` of a store that has not been opened through `AppDatabase`: the "before"
  /// side of every heal assertion.
  public static func unmigratedSchema(ofStoreAt url: URL) throws -> String {
    try readingWithoutMigrating(url) { db in try normalizedSchema(of: db) }
  }

  private static func readingWithoutMigrating<T>(
    _ url: URL, _ body: @Sendable (Database) throws -> T
  ) throws -> T {
    var configuration = Configuration()
    configuration.readonly = true
    return try DatabaseQueue(path: url.path, configuration: configuration).read(body)
  }

  // MARK: - The schema checksum

  /// A normalized `sqlite_master` dump: SQL text with whitespace collapsed, ordered by type then
  /// name, with SQLite's implicit `sqlite_autoindex_*` entries and its internal bookkeeping tables
  /// excluded. Any edit to a registered migration changes this text.
  public static func normalizedSchema(of db: Database) throws -> String {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT type, name, sql FROM sqlite_master
        WHERE name NOT LIKE 'sqlite_autoindex_%'
          AND name NOT IN ('sqlite_sequence', 'grdb_migrations')
        ORDER BY type, name
        """)
    return
      rows
      .map { row -> String in
        let type: String = row["type"] ?? ""
        let name: String = row["name"] ?? ""
        let sql: String = row["sql"] ?? ""
        return "\(type)\t\(name)\t\(collapseWhitespace(sql))"
      }
      .joined(separator: "\n") + "\n"
  }

  private static func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  // MARK: - The fixture tool

  /// Builds a synthetic store at `url` from the current migrator plus the rows below, for fixture
  /// reproducibility checks. It must not replace the committed frozen v1-v3 baseline.
  ///
  /// Built in a scratch store and copied out with `VACUUM INTO`: one file, no `-wal`/`-shm`
  /// sidecars and no free pages to make the bytes vary run to run.
  public static func generateStore(at url: URL) throws {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("released-schema-build-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let buildURL = scratch.appendingPathComponent("build.sqlite")
    let database = try AppDatabase.onDisk(at: buildURL, fileAttributes: InertFileAttributes())
    try database.write { db in
      try insertRows(db)
    }
    try? FileManager.default.removeItem(at: url)
    // `VACUUM` cannot run inside a transaction, which every `read`/`write` here opens.
    try database.dbWriter.writeWithoutTransaction { db in
      try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
    }
  }

  private static func date(_ offsetDays: Double) -> Date {
    // A fixed, obviously synthetic epoch: 2020-01-01T00:00:00Z plus whole days.
    Date(timeIntervalSince1970: 1_577_836_800 + offsetDays * 86_400)
  }

  private static func insertRows(_ db: Database) throws {
    try insertAccounts(db)
    try insertLibrariesAndItems(db)
    try insertProgress(db)
    try insertSessionsAndOutbox(db)
    try insertDownloads(db)
    try insertSyncAndDiagnostics(db)
    try insertBookmarksAndJournal(db)
  }

  private static func insertAccounts(_ db: Database) throws {
    // Two accounts, so account-scoped isolation and the removal sweep both have a negative case.
    try db.execute(
      sql: """
        INSERT INTO account (id, clientUUID, serverBaseURL, serverUserId, serverVersion,
          defaultLibraryId)
        VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        RowID.account, "fixture-client-uuid-a", "fixture-server-a", "fixture-user-a", "2.35.1",
        "fixture-library-a",
        RowID.secondAccount, "fixture-client-uuid-b", "fixture-server-b", "fixture-user-b",
        "2.35.1", nil,
      ])
  }

  private static func insertLibrariesAndItems(_ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO library (id, accountId, serverLibraryId, mediaType, name, lastSeenGeneration)
        VALUES (?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        RowID.library, RowID.account, "fixture-library-a", "book", "Fixture Books", 7,
        2, RowID.secondAccount, "fixture-library-b", "podcast", "Fixture Shows", 3,
      ])

    // A book, a podcast show, and an item owned by the other account.
    try db.execute(
      sql: """
        INSERT INTO item (id, accountId, libraryId, serverItemId, mediaKind, title, sortTitle,
          author, durationSeconds, addedAt, numAudioFiles, ebookFormat, softDeleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
               (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        RowID.bookItem, RowID.account, RowID.library, "fixture-item-book", "book",
        "Fixture Book One", "fixture book one", "Fixture Author", 3600.0, date(10), 3, nil, false,
        RowID.podcastItem, RowID.account, RowID.library, "fixture-item-podcast", "podcast",
        "Fixture Show", "fixture show", nil, nil, date(11), nil, nil, false,
        RowID.secondAccountItem, RowID.secondAccount, 2, "fixture-item-other", "book",
        "Fixture Other", "fixture other", nil, 120.0, date(12), 1, "epub", true,
      ])

    // The item seen-set, carrying each item's sync generation.
    try db.execute(
      sql: """
        INSERT INTO itemSeen (itemId, generation) VALUES (?, ?), (?, ?), (?, ?)
        """,
      arguments: [
        RowID.bookItem, 7, RowID.podcastItem, 7, RowID.secondAccountItem, 3,
      ])

    try db.execute(
      sql: """
        INSERT INTO podcastEpisode (id, accountId, itemId, serverEpisodeId, title, episodeNumber,
          lastSeenGeneration, softDeleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        RowID.episode, RowID.account, RowID.podcastItem, "fixture-episode-1", "Fixture Episode One",
        "1", 7, false,
      ])
  }

  private static func insertProgress(_ db: Database) throws {
    // Item-scoped and episode-scoped progress on the same account, plus a second account's row:
    // the three cases episode work must not disturb.
    try db.execute(
      sql: """
        INSERT INTO mediaProgress (id, accountId, itemId, podcastEpisodeId, currentTime,
          isFinished, serverUpdatedAt, localSequence, origin, originKey)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
               (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        RowID.itemProgress, RowID.account, RowID.bookItem, nil, 1234.5, false, date(13), 4,
        "server", "fixture-origin-item",
        RowID.episodeProgress, RowID.account, RowID.podcastItem, RowID.episode, 67.25, false,
        date(14), 2, "local", "fixture-origin-episode",
        3, RowID.secondAccount, RowID.secondAccountItem, nil, 0.0, true, nil, 1, "server",
        "fixture-origin-other",
      ])

    try db.execute(
      sql: """
        INSERT INTO progressConflict (id, accountId, itemId, serverCurrentTime, serverIsFinished,
          serverUpdatedAt, detectedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [1, RowID.account, RowID.bookItem, 999.0, false, date(15), date(15)])
  }

  private static func insertSessionsAndOutbox(_ db: Database) throws {
    // One closed streaming session and one closed offline session. Both are `closed` so the two
    // partial "one active session per account" unique indexes stay satisfiable.
    try db.execute(
      sql: """
        INSERT INTO playbackSession (id, accountId, clientSessionId, serverSessionId, itemId,
          podcastEpisodeId, startedAt, updatedAt, listenedDeltaSeconds, closePending, isOffline,
          globalPosition, duration, state, lastLocalSequence)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        RowID.session, RowID.account, "fixture-client-session-1", "fixture-server-session-1",
        RowID.bookItem, nil, date(16), date(16), 300.0, false, false, 1234.5, 3600.0, "closed", 4,
        2, RowID.account, "fixture-client-session-2", nil, RowID.podcastItem, RowID.episode,
        date(17), date(17), 60.0, true, true, 67.25, nil, "closed", 2,
      ])

    // A pending progress operation and a dead-lettered one, so the outbox's drain index and its
    // session foreign key are both exercised.
    try db.execute(
      sql: """
        INSERT INTO outboxOperation (id, accountId, clientOperationId, entityKey, operationKind,
          coalescingKey, payloadVersion, localSequence, attempts, nextAttemptAt, state,
          payloadCurrentTime, payloadIsFinished, payloadAccumulatedDeltaSeconds,
          payloadDurationSeconds, playbackSessionId, deadLetterReason)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
               (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        1, RowID.account, "fixture-operation-1", "fixture-entity-item", "progress",
        "fixture-coalescing-1", 1, 4, 0, date(18), "pending", 1234.5, false, 300.0, 3600.0,
        RowID.session, nil,
        2, RowID.account, "fixture-operation-2", "fixture-entity-episode", "progress",
        "fixture-coalescing-2", 1, 2, 5, nil, "deadLettered", 67.25, false, 60.0, nil, 2,
        "fixture-reason",
      ])
  }

  private static func insertDownloads(_ db: Database) throws {
    // One item-scoped and one episode-scoped download: the two partial unique indexes on
    // `download` only both apply when each shape is present.
    try db.execute(
      sql: """
        INSERT INTO download (id, accountId, itemId, podcastEpisodeId, serverFileIno, orderIndex,
          destinationRelativePath, expectedBytes, expectedMimeType, fileDurationSeconds,
          receivedBytes, resumeData, state, holdReason, errorCategory)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        1, RowID.account, RowID.bookItem, nil, "fixture-ino-1", 0, "fixture/book/track-1.m4b",
        1024, "audio/mp4", 3600.0, 1024, nil, "completed", nil, nil,
        2, RowID.account, RowID.podcastItem, RowID.episode, "fixture-ino-2", 0,
        "fixture/show/episode-1.mp3", 2048, "audio/mpeg", 600.0, 512, nil, "paused",
        "fixture-hold", nil,
      ])
  }

  private static func insertSyncAndDiagnostics(_ db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO syncRun (id, accountId, libraryId, reason, generation, startedAt, completedAt,
          state, errorCategory, sortRequested)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        RowID.syncRun, RowID.account, RowID.library, "foreground", 7, date(19), date(19),
        "completed", nil, "fixture-sort",
      ])

    try db.execute(
      sql: """
        INSERT INTO syncPage (id, accountId, syncRunId, pageNumber, itemCount, fetchedAt,
          resultCategory)
        VALUES (?, ?, ?, ?, ?, ?, ?), (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        1, RowID.account, RowID.syncRun, 0, 50, date(19), "ok",
        2, RowID.account, RowID.syncRun, 1, 12, date(19), "ok",
      ])

    try db.execute(
      sql: """
        INSERT INTO diagnosticsEvent (id, accountId, category, statusClass, durationMilliseconds,
          endpointTemplate, occurredAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        1, RowID.account, "sync", "2xx", 123.0, "/api/libraries/{id}/items", date(19),
      ])

    try db.execute(
      sql: """
        INSERT INTO observedServerTime (id, accountId, offsetSeconds, observedAt)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [1, RowID.account, -1.5, date(19)])

    try db.execute(
      sql: """
        INSERT INTO listeningHistoryEntry (id, accountId, itemId, sessionId, startedAt,
          startPosition, endPosition, listenedSeconds)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        1, RowID.account, RowID.bookItem, "fixture-history-session", date(16), 934.5, 1234.5, 300.0,
      ])
  }

  private static func insertBookmarksAndJournal(_ db: Database) throws {
    // One bookmark per account (the unique index allows no more).
    try db.execute(
      sql: """
        INSERT INTO playbackBookmark (id, accountId, itemId, podcastEpisodeId, updatedAt)
        VALUES (?, ?, ?, ?, ?), (?, ?, ?, ?, ?)
        """,
      arguments: [
        1, RowID.account, RowID.podcastItem, RowID.episode, date(17),
        2, RowID.secondAccount, RowID.secondAccountItem, nil, date(12),
      ])

    // Account-FK-free, so it survives the removal sweep it describes.
    try db.execute(
      sql: """
        INSERT INTO accountRemovalJournal (id, serverBaseURL, serverUserId, accountRowId,
          downloadsRootRelativePath, createdAt)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        1, "fixture-server-c", "fixture-user-c", 99, "fixture/downloads", date(20),
      ])
  }
}
