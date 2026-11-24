import Foundation
import GRDB
import Persistence

/// Committed store fixtures for the drifted schemas that real devices carry, plus the reviewed tool
/// that regenerates them.
///
/// `v1` was amended in place over time (see SchemaV1.swift's header). GRDB never revisits an
/// applied migration, so a store created before an amendment lacks its tables, columns and
/// indexes though `grdb_migrations` says `v1` ran. Only two amendments got a heal (`v2`, `v3`), so
/// a device store reports `v1,v2,v3` applied while missing four whole tables. `v4` is the general
/// heal; these fixtures prove it converges.
///
/// Each shape reconstructs a historical `v1` closure as literal DDL, since the shapes no longer
/// exist in the source tree. `Shape.fieldObserved` is transcribed from a schema-only dump of an
/// actual simulator store.
///
/// Like `ReleasedSchemaFixture`, the stores are referentially populated through the real foreign
/// keys, so `PRAGMA foreign_key_check`, the account-removal sweep and "no row lost in the rebuild"
/// have something to prove. Every value is synthetic.
///
/// Regenerate the committed store with:
///
///     REGENERATE_DRIFTED_SCHEMA_FIXTURE=1 swift test --filter RegenerateDriftedSchemaFixture
public enum DriftedSchemaFixture {

  public static let storeResourceName = "drifted-schema-field"
  public static let storeResourceExtension = "sqlite"

  /// What a drifted store claims to have applied. This is true, yet the schema is incomplete.
  public static let appliedMigrations = ["v1", "v2", "v3"]

  // MARK: - Shapes

  public enum Shape: String, CaseIterable, Sendable {
    /// Transcribed from a real device store. Lacks `progressConflict`, `observedServerTime`,
    /// `accountRemovalJournal` and `listeningHistoryEntry`. Has the early `download` stub
    /// (nullable `expectedBytes`, retired `errorReason`, no transfer columns or unique indexes),
    /// no offline-session index, and `item` in `v2`'s ALTER-appended column order.
    case fieldObserved

    /// A later store than `fieldObserved`: `download` is full-shape and the offline-session index
    /// and `accountRemovalJournal` exist, but `observedServerTime`, `progressConflict` and
    /// `listeningHistoryEntry` do not. Proves the heal converges from partial drift.
    case afterRemovalJournal

    /// The oldest shape still plausible on a development device: `playbackSession` has none of the
    /// position/duration/state columns, and `outboxOperation` is missing
    /// `payloadDurationSeconds`/`playbackSessionId`. Those sit in the middle of the current column
    /// list, so appending them could never reproduce the current shape.
    case beforeSessionColumns
  }

  // MARK: - Loading the committed fixture

  public enum FixtureError: Error, Equatable {
    case resourceMissing(String)
  }

  /// Copies the committed drifted store into `directory` and returns the copy's URL. Migrating
  /// writes, so the bundled bytes are never opened directly.
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

  /// Reads the applied migration identifiers without migrating, so a test can assert what the
  /// committed bytes carry rather than what opening them produces.
  public static func appliedMigrations(inStoreAt url: URL) throws -> [String] {
    try ReleasedSchemaFixture.appliedMigrations(inStoreAt: url)
  }

  /// The normalized `sqlite_master` dump of a store, without migrating it. Reuses
  /// `ReleasedSchemaFixture`'s normalizer so "drifted" and "healed" are measured the same way.
  public static func unmigratedSchema(ofStoreAt url: URL) throws -> String {
    try ReleasedSchemaFixture.unmigratedSchema(ofStoreAt: url)
  }

  // MARK: - Row expectations

  /// Every table each shape populates, with the number of rows it carries. The heal tests assert
  /// each count survives `v4` unchanged, so a table rebuild that dropped a row shows up here.
  public static func expectedRowCounts(for shape: Shape) -> [String: Int] {
    var counts: [String: Int] = [
      "account": 2,
      "library": 2,
      "item": 3,
      "podcastEpisode": 1,
      "mediaProgress": 3,
      "playbackSession": 2,
      "outboxOperation": 2,
      "download": 2,
      "syncRun": 1,
      "syncPage": 2,
      "diagnosticsEvent": 1,
      "playbackBookmark": 2,
    ]
    if shape == .afterRemovalJournal {
      counts["accountRemovalJournal"] = 1
    }
    return counts
  }

  /// Tables that only exist after the heal, so they start (and stay) empty.
  public static func tablesCreatedByTheHeal(for shape: Shape) -> [String] {
    switch shape {
    case .fieldObserved, .beforeSessionColumns:
      return [
        "progressConflict", "observedServerTime", "accountRemovalJournal", "listeningHistoryEntry",
      ]
    case .afterRemovalJournal:
      return ["progressConflict", "observedServerTime", "listeningHistoryEntry"]
    }
  }

  /// Mirrors `ReleasedSchemaFixture.tablesSurvivingAccountRemoval`: the removal journal is not
  /// account-owned.
  public static let tablesSurvivingAccountRemoval = ["accountRemovalJournal"]

  public enum RowID {
    public static let account: Int64 = 1
    public static let secondAccount: Int64 = 2
    public static let library: Int64 = 1
    public static let bookItem: Int64 = 1
    public static let podcastItem: Int64 = 2
    public static let secondAccountItem: Int64 = 3
    public static let episode: Int64 = 1
    public static let session: Int64 = 1
    public static let legacyItemDownload: Int64 = 1
    public static let legacyEpisodeDownload: Int64 = 2
  }

  // MARK: - The fixture tool

  /// Builds a drifted store at `url` from `shape`'s historical DDL plus the synthetic rows below.
  /// This is the only sanctioned way the committed fixture is produced.
  ///
  /// Built in a scratch store and copied out with `VACUUM INTO`, like
  /// `ReleasedSchemaFixture.generateStore(at:)`, so the artifact is one file with no sidecars.
  public static func generateStore(at url: URL, shape: Shape) throws {
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("drifted-schema-build-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }

    let buildURL = scratch.appendingPathComponent("build.sqlite")
    let queue = try DatabaseQueue(path: buildURL.path)
    try queue.write { db in
      for statement in statements(for: shape) {
        try db.execute(sql: statement)
      }
      // GRDB's own bookkeeping table, stamped as a real drifted store carries it: `v1` "applied"
      // before most of what `v1` now creates existed.
      try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
      for identifier in appliedMigrations {
        try db.execute(
          sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
      }
      try insertRows(db, shape: shape)
    }
    try? FileManager.default.removeItem(at: url)
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
    }
  }

  // MARK: - Historical DDL

  private static func statements(for shape: Shape) -> [String] {
    var statements = [
      // Includes `defaultLibraryId`.
      """
      CREATE TABLE "account" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "clientUUID" TEXT NOT NULL \
      UNIQUE, "serverBaseURL" TEXT NOT NULL, "serverUserId" TEXT NOT NULL, "serverVersion" TEXT \
      NOT NULL, "defaultLibraryId" TEXT)
      """,
      """
      CREATE UNIQUE INDEX "index_account_on_serverBaseURL_serverUserId" ON \
      "account"("serverBaseURL", "serverUserId")
      """,
      """
      CREATE TABLE "library" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER NOT NULL \
      REFERENCES "account"("id") ON DELETE CASCADE, "serverLibraryId" TEXT NOT NULL, "mediaType" \
      TEXT NOT NULL, "name" TEXT NOT NULL, "lastSeenGeneration" INTEGER NOT NULL DEFAULT 0)
      """,
      #"CREATE INDEX "library_on_accountId" ON "library"("accountId")"#,
      """
      CREATE UNIQUE INDEX "index_library_on_account_serverLibraryId" ON "library"("accountId", \
      "serverLibraryId")
      """,
      // Three columns sit at the end here: `v2`'s heal adds them with `ALTER TABLE ... ADD
      // COLUMN`, which can only append. A newer store has them mid-list, so this ordering is part
      // of the drift the heal has to converge.
      """
      CREATE TABLE "item" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER NOT NULL \
      REFERENCES "account"("id") ON DELETE CASCADE, "libraryId" INTEGER NOT NULL REFERENCES \
      "library"("id") ON DELETE CASCADE, "serverItemId" TEXT NOT NULL, "mediaKind" TEXT NOT NULL, \
      "title" TEXT NOT NULL, "sortTitle" TEXT NOT NULL, "author" TEXT, "durationSeconds" DOUBLE, \
      "lastSeenGeneration" INTEGER NOT NULL, "softDeleted" BOOLEAN NOT NULL DEFAULT 0, \
      "ebookFormat" TEXT, "addedAt" DATETIME, "numAudioFiles" INTEGER)
      """,
      #"CREATE INDEX "item_on_accountId" ON "item"("accountId")"#,
      #"CREATE INDEX "item_on_libraryId" ON "item"("libraryId")"#,
      """
      CREATE UNIQUE INDEX "index_item_on_library_serverItemId" ON "item"("libraryId", \
      "serverItemId")
      """,
      """
      CREATE INDEX "index_item_browse" ON "item"("libraryId", "softDeleted", "sortTitle")
      """,
      """
      CREATE TABLE "podcastEpisode" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER \
      NOT NULL REFERENCES "account"("id") ON DELETE CASCADE, "itemId" INTEGER NOT NULL REFERENCES \
      "item"("id") ON DELETE CASCADE, "serverEpisodeId" TEXT NOT NULL, "title" TEXT NOT NULL, \
      "episodeNumber" TEXT, "lastSeenGeneration" INTEGER NOT NULL, "softDeleted" BOOLEAN NOT NULL \
      DEFAULT 0)
      """,
      #"CREATE INDEX "podcastEpisode_on_accountId" ON "podcastEpisode"("accountId")"#,
      #"CREATE INDEX "podcastEpisode_on_itemId" ON "podcastEpisode"("itemId")"#,
      """
      CREATE UNIQUE INDEX "index_podcastEpisode_on_item_serverEpisodeId" ON \
      "podcastEpisode"("itemId", "serverEpisodeId")
      """,
      """
      CREATE TABLE "mediaProgress" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER NOT \
      NULL REFERENCES "account"("id") ON DELETE CASCADE, "itemId" INTEGER NOT NULL REFERENCES \
      "item"("id") ON DELETE CASCADE, "podcastEpisodeId" INTEGER REFERENCES "podcastEpisode"("id") \
      ON DELETE CASCADE, "currentTime" DOUBLE NOT NULL, "isFinished" BOOLEAN NOT NULL, \
      "serverUpdatedAt" DATETIME, "localSequence" INTEGER NOT NULL, "origin" TEXT NOT NULL, \
      "originKey" TEXT NOT NULL)
      """,
      #"CREATE INDEX "mediaProgress_on_accountId" ON "mediaProgress"("accountId")"#,
      #"CREATE INDEX "mediaProgress_on_itemId" ON "mediaProgress"("itemId")"#,
      #"CREATE INDEX "mediaProgress_on_podcastEpisodeId" ON "mediaProgress"("podcastEpisodeId")"#,
      """
      CREATE UNIQUE INDEX "index_mediaProgress_on_account_item" ON "mediaProgress"("accountId", \
      "itemId") WHERE "podcastEpisodeId" IS NULL
      """,
      """
      CREATE UNIQUE INDEX "index_mediaProgress_on_account_episode" ON "mediaProgress"("accountId", \
      "podcastEpisodeId") WHERE "podcastEpisodeId" IS NOT NULL
      """,
    ]

    statements += playbackSessionStatements(for: shape)
    statements += outboxOperationStatements(for: shape)
    statements += downloadStatements(for: shape)

    statements += [
      """
      CREATE TABLE "syncRun" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER NOT NULL \
      REFERENCES "account"("id") ON DELETE CASCADE, "libraryId" INTEGER REFERENCES "library"("id") \
      ON DELETE CASCADE, "reason" TEXT NOT NULL, "generation" INTEGER NOT NULL, "startedAt" \
      DATETIME NOT NULL, "completedAt" DATETIME, "state" TEXT NOT NULL, "errorCategory" TEXT, \
      "sortRequested" TEXT)
      """,
      #"CREATE INDEX "syncRun_on_accountId" ON "syncRun"("accountId")"#,
      #"CREATE INDEX "syncRun_on_libraryId" ON "syncRun"("libraryId")"#,
      """
      CREATE TABLE "syncPage" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER NOT NULL \
      REFERENCES "account"("id") ON DELETE CASCADE, "syncRunId" INTEGER NOT NULL REFERENCES \
      "syncRun"("id") ON DELETE CASCADE, "pageNumber" INTEGER NOT NULL, "itemCount" INTEGER NOT \
      NULL, "fetchedAt" DATETIME NOT NULL, "resultCategory" TEXT)
      """,
      #"CREATE INDEX "syncPage_on_accountId" ON "syncPage"("accountId")"#,
      #"CREATE INDEX "syncPage_on_syncRunId" ON "syncPage"("syncRunId")"#,
      """
      CREATE UNIQUE INDEX "index_syncPage_on_syncRun_pageNumber" ON "syncPage"("syncRunId", \
      "pageNumber")
      """,
      """
      CREATE TABLE "diagnosticsEvent" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER \
      NOT NULL REFERENCES "account"("id") ON DELETE CASCADE, "category" TEXT NOT NULL, \
      "statusClass" TEXT NOT NULL, "durationMilliseconds" DOUBLE NOT NULL, "endpointTemplate" TEXT, \
      "occurredAt" DATETIME NOT NULL)
      """,
      #"CREATE INDEX "diagnosticsEvent_on_accountId" ON "diagnosticsEvent"("accountId")"#,
      """
      CREATE INDEX "index_diagnosticsEvent_on_account_id" ON "diagnosticsEvent"("accountId", "id")
      """,
    ]

    if shape == .afterRemovalJournal {
      statements.append(
        """
        CREATE TABLE "accountRemovalJournal" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, \
        "serverBaseURL" TEXT NOT NULL, "serverUserId" TEXT NOT NULL, "accountRowId" INTEGER NOT \
        NULL, "downloadsRootRelativePath" TEXT NOT NULL, "createdAt" DATETIME NOT NULL)
        """)
    }

    // Created by `v2` and `v3`, which every drifted store has applied. They are the two
    // amendments that got a heal, and the reason such a store still opens at all.
    statements += [
      """
      CREATE INDEX "index_item_recently_added" ON "item"("accountId", "softDeleted", "addedAt")
      """,
      """
      CREATE TABLE "playbackBookmark" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER \
      NOT NULL REFERENCES "account"("id") ON DELETE CASCADE, "itemId" INTEGER NOT NULL REFERENCES \
      "item"("id") ON DELETE CASCADE, "podcastEpisodeId" INTEGER REFERENCES "podcastEpisode"("id") \
      ON DELETE CASCADE, "updatedAt" DATETIME NOT NULL)
      """,
      #"CREATE INDEX "playbackBookmark_on_accountId" ON "playbackBookmark"("accountId")"#,
      #"CREATE INDEX "playbackBookmark_on_itemId" ON "playbackBookmark"("itemId")"#,
      """
      CREATE INDEX "playbackBookmark_on_podcastEpisodeId" ON \
      "playbackBookmark"("podcastEpisodeId")
      """,
      """
      CREATE UNIQUE INDEX "index_playbackBookmark_on_account" ON "playbackBookmark"("accountId")
      """,
    ]

    return statements
  }

  private static func playbackSessionStatements(for shape: Shape) -> [String] {
    let sharedIndexes = [
      #"CREATE INDEX "playbackSession_on_accountId" ON "playbackSession"("accountId")"#,
      #"CREATE INDEX "playbackSession_on_itemId" ON "playbackSession"("itemId")"#,
      #"CREATE INDEX "playbackSession_on_podcastEpisodeId" ON "playbackSession"("podcastEpisodeId")"#,
    ]
    let head = """
      CREATE TABLE "playbackSession" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER \
      NOT NULL REFERENCES "account"("id") ON DELETE CASCADE, "clientSessionId" TEXT NOT NULL \
      UNIQUE, "serverSessionId" TEXT, "itemId" INTEGER NOT NULL REFERENCES "item"("id") ON DELETE \
      CASCADE, "podcastEpisodeId" INTEGER REFERENCES "podcastEpisode"("id") ON DELETE CASCADE, \
      "startedAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL, "listenedDeltaSeconds" DOUBLE \
      NOT NULL DEFAULT 0, "closePending" BOOLEAN NOT NULL DEFAULT 0, "isOffline" BOOLEAN NOT NULL \
      DEFAULT 0
      """
    switch shape {
    case .beforeSessionColumns:
      return [head + ")"] + sharedIndexes
    case .fieldObserved:
      return [
        head + """
          , "globalPosition" DOUBLE NOT NULL DEFAULT 0, "duration" DOUBLE, "state" TEXT NOT NULL \
          DEFAULT 'active', "lastLocalSequence" INTEGER NOT NULL DEFAULT 0)
          """
      ]
        + sharedIndexes
        + [
          """
          CREATE UNIQUE INDEX "index_playbackSession_one_active_per_account" ON \
          "playbackSession"("accountId") WHERE ("isOffline" = 0) AND ("state" = 'active')
          """
        ]
    case .afterRemovalJournal:
      return [
        head + """
          , "globalPosition" DOUBLE NOT NULL DEFAULT 0, "duration" DOUBLE, "state" TEXT NOT NULL \
          DEFAULT 'active', "lastLocalSequence" INTEGER NOT NULL DEFAULT 0)
          """
      ]
        + sharedIndexes
        + [
          """
          CREATE UNIQUE INDEX "index_playbackSession_one_active_per_account" ON \
          "playbackSession"("accountId") WHERE ("isOffline" = 0) AND ("state" = 'active')
          """,
          """
          CREATE UNIQUE INDEX "index_playbackSession_one_active_offline_per_account" ON \
          "playbackSession"("accountId") WHERE ("isOffline" = 1) AND ("state" = 'active')
          """,
        ]
    }
  }

  private static func outboxOperationStatements(for shape: Shape) -> [String] {
    let head = """
      CREATE TABLE "outboxOperation" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER \
      NOT NULL REFERENCES "account"("id") ON DELETE CASCADE, "clientOperationId" TEXT NOT NULL \
      UNIQUE, "entityKey" TEXT NOT NULL, "operationKind" TEXT NOT NULL, "coalescingKey" TEXT NOT \
      NULL, "payloadVersion" INTEGER NOT NULL, "localSequence" INTEGER NOT NULL, "attempts" \
      INTEGER NOT NULL DEFAULT 0, "nextAttemptAt" DATETIME, "state" TEXT NOT NULL, \
      "payloadCurrentTime" DOUBLE, "payloadIsFinished" BOOLEAN, "payloadAccumulatedDeltaSeconds" \
      DOUBLE
      """
    let drainIndex = """
      CREATE INDEX "index_outboxOperation_drain" ON "outboxOperation"("state", "nextAttemptAt")
      """
    switch shape {
    case .beforeSessionColumns:
      // The current shape has `payloadDurationSeconds`/`playbackSessionId` before
      // `deadLetterReason`, so healing this shape by appending could never reach that order.
      return [
        head + #", "deadLetterReason" TEXT)"#,
        #"CREATE INDEX "outboxOperation_on_accountId" ON "outboxOperation"("accountId")"#,
        drainIndex,
      ]
    case .fieldObserved, .afterRemovalJournal:
      return [
        head + """
          , "payloadDurationSeconds" DOUBLE, "playbackSessionId" INTEGER REFERENCES \
          "playbackSession"("id") ON DELETE CASCADE, "deadLetterReason" TEXT)
          """,
        #"CREATE INDEX "outboxOperation_on_accountId" ON "outboxOperation"("accountId")"#,
        #"CREATE INDEX "outboxOperation_on_playbackSessionId" ON "outboxOperation"("playbackSessionId")"#,
        drainIndex,
        """
        CREATE INDEX "index_outboxOperation_on_playbackSession" ON \
        "outboxOperation"("playbackSessionId")
        """,
      ]
    }
  }

  private static func downloadStatements(for shape: Shape) -> [String] {
    let sharedIndexes = [
      #"CREATE INDEX "download_on_accountId" ON "download"("accountId")"#,
      #"CREATE INDEX "download_on_itemId" ON "download"("itemId")"#,
      #"CREATE INDEX "download_on_podcastEpisodeId" ON "download"("podcastEpisodeId")"#,
    ]
    switch shape {
    case .fieldObserved, .beforeSessionColumns:
      // Early stub: nullable `expectedBytes`, free-text `errorReason`, and no transfer
      // identity/metadata columns.
      return [
        """
        CREATE TABLE "download" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER NOT \
        NULL REFERENCES "account"("id") ON DELETE CASCADE, "itemId" INTEGER NOT NULL REFERENCES \
        "item"("id") ON DELETE CASCADE, "podcastEpisodeId" INTEGER REFERENCES \
        "podcastEpisode"("id") ON DELETE CASCADE, "destinationRelativePath" TEXT NOT NULL, \
        "expectedBytes" INTEGER, "receivedBytes" INTEGER NOT NULL DEFAULT 0, "resumeData" BLOB, \
        "state" TEXT NOT NULL, "errorReason" TEXT)
        """
      ] + sharedIndexes
    case .afterRemovalJournal:
      return [
        """
        CREATE TABLE "download" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "accountId" INTEGER NOT \
        NULL REFERENCES "account"("id") ON DELETE CASCADE, "itemId" INTEGER NOT NULL REFERENCES \
        "item"("id") ON DELETE CASCADE, "podcastEpisodeId" INTEGER REFERENCES \
        "podcastEpisode"("id") ON DELETE CASCADE, "serverFileIno" TEXT NOT NULL, "orderIndex" \
        INTEGER NOT NULL, "destinationRelativePath" TEXT NOT NULL, "expectedBytes" INTEGER NOT \
        NULL, "expectedMimeType" TEXT NOT NULL, "fileDurationSeconds" DOUBLE NOT NULL, \
        "receivedBytes" INTEGER NOT NULL DEFAULT 0, "resumeData" BLOB, "state" TEXT NOT NULL, \
        "holdReason" TEXT, "errorCategory" TEXT)
        """
      ]
        + sharedIndexes
        + [
          """
          CREATE UNIQUE INDEX "index_download_on_account_item_fileIno" ON "download"("accountId", \
          "itemId", "serverFileIno") WHERE "podcastEpisodeId" IS NULL
          """,
          """
          CREATE UNIQUE INDEX "index_download_on_account_item_episode_fileIno" ON \
          "download"("accountId", "itemId", "podcastEpisodeId", "serverFileIno") WHERE \
          "podcastEpisodeId" IS NOT NULL
          """,
        ]
    }
  }

  // MARK: - Synthetic rows

  private static func date(_ offsetDays: Double) -> Date {
    // The same fixed, synthetic epoch `ReleasedSchemaFixture` uses: 2020-01-01T00:00:00Z.
    Date(timeIntervalSince1970: 1_577_836_800 + offsetDays * 86_400)
  }

  /// Inserts one row set, filtered to the columns each shape's tables actually have. Driving the
  /// inserts off `PRAGMA table_info` rather than per-shape SQL is what keeps three historical
  /// shapes from needing three copies of the same data.
  private static func insertRows(_ db: Database, shape: Shape) throws {
    try insert(
      db, "account",
      [
        [
          "id": RowID.account, "clientUUID": "fixture-client-uuid-a",
          "serverBaseURL": "fixture-server-a", "serverUserId": "fixture-user-a",
          "serverVersion": "2.35.1", "defaultLibraryId": "fixture-library-a",
        ],
        [
          "id": RowID.secondAccount, "clientUUID": "fixture-client-uuid-b",
          "serverBaseURL": "fixture-server-b", "serverUserId": "fixture-user-b",
          "serverVersion": "2.35.1", "defaultLibraryId": nil,
        ],
      ])

    try insert(
      db, "library",
      [
        [
          "id": RowID.library, "accountId": RowID.account, "serverLibraryId": "fixture-library-a",
          "mediaType": "book", "name": "Fixture Books", "lastSeenGeneration": 7,
        ],
        [
          "id": 2, "accountId": RowID.secondAccount, "serverLibraryId": "fixture-library-b",
          "mediaType": "podcast", "name": "Fixture Shows", "lastSeenGeneration": 3,
        ],
      ])

    try insert(
      db, "item",
      [
        [
          "id": RowID.bookItem, "accountId": RowID.account, "libraryId": RowID.library,
          "serverItemId": "fixture-item-book", "mediaKind": "book", "title": "Fixture Book One",
          "sortTitle": "fixture book one", "author": "Fixture Author", "durationSeconds": 3600.0,
          "addedAt": date(10), "numAudioFiles": 3, "ebookFormat": nil, "lastSeenGeneration": 7,
          "softDeleted": false,
        ],
        [
          "id": RowID.podcastItem, "accountId": RowID.account, "libraryId": RowID.library,
          "serverItemId": "fixture-item-podcast", "mediaKind": "podcast", "title": "Fixture Show",
          "sortTitle": "fixture show", "author": nil, "durationSeconds": nil, "addedAt": date(11),
          "numAudioFiles": nil, "ebookFormat": nil, "lastSeenGeneration": 7, "softDeleted": false,
        ],
        [
          "id": RowID.secondAccountItem, "accountId": RowID.secondAccount, "libraryId": 2,
          "serverItemId": "fixture-item-other", "mediaKind": "book", "title": "Fixture Other",
          "sortTitle": "fixture other", "author": nil, "durationSeconds": 120.0,
          "addedAt": date(12), "numAudioFiles": 1, "ebookFormat": "epub", "lastSeenGeneration": 3,
          "softDeleted": true,
        ],
      ])

    try insert(
      db, "podcastEpisode",
      [
        [
          "id": RowID.episode, "accountId": RowID.account, "itemId": RowID.podcastItem,
          "serverEpisodeId": "fixture-episode-1", "title": "Fixture Episode One",
          "episodeNumber": "1", "lastSeenGeneration": 7, "softDeleted": false,
        ]
      ])

    try insert(
      db, "mediaProgress",
      [
        [
          "id": 1, "accountId": RowID.account, "itemId": RowID.bookItem, "podcastEpisodeId": nil,
          "currentTime": 1234.5, "isFinished": false, "serverUpdatedAt": date(13),
          "localSequence": 4, "origin": "server", "originKey": "fixture-origin-item",
        ],
        [
          "id": 2, "accountId": RowID.account, "itemId": RowID.podcastItem,
          "podcastEpisodeId": RowID.episode, "currentTime": 67.25, "isFinished": false,
          "serverUpdatedAt": date(14), "localSequence": 2, "origin": "local",
          "originKey": "fixture-origin-episode",
        ],
        [
          "id": 3, "accountId": RowID.secondAccount, "itemId": RowID.secondAccountItem,
          "podcastEpisodeId": nil, "currentTime": 0.0, "isFinished": true, "serverUpdatedAt": nil,
          "localSequence": 1, "origin": "server", "originKey": "fixture-origin-other",
        ],
      ])

    // One online and one offline session. `beforeSessionColumns` has no `state` column, so the heal
    // fills it from the schema default (`active`). At most one of each kind per account, which is
    // what the two partial unique indexes it also creates allow.
    try insert(
      db, "playbackSession",
      [
        [
          "id": RowID.session, "accountId": RowID.account,
          "clientSessionId": "fixture-client-session-1",
          "serverSessionId": "fixture-server-session-1", "itemId": RowID.bookItem,
          "podcastEpisodeId": nil, "startedAt": date(16), "updatedAt": date(16),
          "listenedDeltaSeconds": 300.0, "closePending": false, "isOffline": false,
          "globalPosition": 1234.5, "duration": 3600.0, "state": "active", "lastLocalSequence": 4,
        ],
        [
          "id": 2, "accountId": RowID.account, "clientSessionId": "fixture-client-session-2",
          "serverSessionId": nil, "itemId": RowID.podcastItem, "podcastEpisodeId": RowID.episode,
          "startedAt": date(17), "updatedAt": date(17), "listenedDeltaSeconds": 60.0,
          "closePending": true, "isOffline": true, "globalPosition": 67.25, "duration": nil,
          "state": "active", "lastLocalSequence": 2,
        ],
      ])

    try insert(
      db, "outboxOperation",
      [
        [
          "id": 1, "accountId": RowID.account, "clientOperationId": "fixture-operation-1",
          "entityKey": "fixture-entity-item", "operationKind": "progress",
          "coalescingKey": "fixture-coalescing-1", "payloadVersion": 1, "localSequence": 4,
          "attempts": 0, "nextAttemptAt": date(18), "state": "pending",
          "payloadCurrentTime": 1234.5, "payloadIsFinished": false,
          "payloadAccumulatedDeltaSeconds": 300.0, "payloadDurationSeconds": 3600.0,
          "playbackSessionId": RowID.session, "deadLetterReason": nil,
        ],
        [
          "id": 2, "accountId": RowID.account, "clientOperationId": "fixture-operation-2",
          "entityKey": "fixture-entity-episode", "operationKind": "progress",
          "coalescingKey": "fixture-coalescing-2", "payloadVersion": 1, "localSequence": 2,
          "attempts": 5, "nextAttemptAt": nil, "state": "deadLettered",
          "payloadCurrentTime": 67.25, "payloadIsFinished": false,
          "payloadAccumulatedDeltaSeconds": 60.0, "payloadDurationSeconds": nil,
          "playbackSessionId": 2, "deadLetterReason": "fixture-reason",
        ],
      ])

    // The legacy `download` rows carry the two states the heal has to decide about: a NULL
    // `expectedBytes` (only expressible while the column is still nullable) and a non-NULL retired
    // `errorReason`. The already-current shape carries the current equivalents instead, so the
    // heal's "leave a current table alone" path has a row to prove it on.
    let legacyExpectedBytes: (any DatabaseValueConvertible)? =
      shape == .afterRemovalJournal ? Int64(1024) : nil
    try insert(
      db, "download",
      [
        [
          "id": RowID.legacyItemDownload, "accountId": RowID.account, "itemId": RowID.bookItem,
          "podcastEpisodeId": nil, "serverFileIno": "fixture-ino-1", "orderIndex": 0,
          "destinationRelativePath": "fixture/book/track-1.m4b",
          "expectedBytes": legacyExpectedBytes,
          "expectedMimeType": "audio/mp4", "fileDurationSeconds": 3600.0, "receivedBytes": 1024,
          "resumeData": nil, "state": "failed", "holdReason": nil,
          "errorReason": "fixture-legacy-error", "errorCategory": nil,
        ],
        [
          "id": RowID.legacyEpisodeDownload, "accountId": RowID.account,
          "itemId": RowID.podcastItem, "podcastEpisodeId": RowID.episode,
          "serverFileIno": "fixture-ino-2", "orderIndex": 0,
          "destinationRelativePath": "fixture/show/episode-1.mp3", "expectedBytes": 2048,
          "expectedMimeType": "audio/mpeg", "fileDurationSeconds": 600.0, "receivedBytes": 512,
          "resumeData": nil, "state": "paused", "holdReason": nil, "errorReason": nil,
          "errorCategory": nil,
        ],
      ])

    try insert(
      db, "syncRun",
      [
        [
          "id": 1, "accountId": RowID.account, "libraryId": RowID.library, "reason": "foreground",
          "generation": 7, "startedAt": date(19), "completedAt": date(19), "state": "completed",
          "errorCategory": nil, "sortRequested": "fixture-sort",
        ]
      ])

    try insert(
      db, "syncPage",
      [
        [
          "id": 1, "accountId": RowID.account, "syncRunId": 1, "pageNumber": 0, "itemCount": 50,
          "fetchedAt": date(19), "resultCategory": "ok",
        ],
        [
          "id": 2, "accountId": RowID.account, "syncRunId": 1, "pageNumber": 1, "itemCount": 12,
          "fetchedAt": date(19), "resultCategory": "ok",
        ],
      ])

    try insert(
      db, "diagnosticsEvent",
      [
        [
          "id": 1, "accountId": RowID.account, "category": "sync", "statusClass": "2xx",
          "durationMilliseconds": 123.0, "endpointTemplate": "/api/libraries/{id}/items",
          "occurredAt": date(19),
        ]
      ])

    try insert(
      db, "playbackBookmark",
      [
        [
          "id": 1, "accountId": RowID.account, "itemId": RowID.podcastItem,
          "podcastEpisodeId": RowID.episode, "updatedAt": date(17),
        ],
        [
          "id": 2, "accountId": RowID.secondAccount, "itemId": RowID.secondAccountItem,
          "podcastEpisodeId": nil, "updatedAt": date(12),
        ],
      ])

    try insert(
      db, "accountRemovalJournal",
      [
        [
          "id": 1, "serverBaseURL": "fixture-server-c", "serverUserId": "fixture-user-c",
          "accountRowId": 99, "downloadsRootRelativePath": "fixture/downloads",
          "createdAt": date(20),
        ]
      ])
  }

  private static func insert(
    _ db: Database, _ table: String, _ rows: [[String: (any DatabaseValueConvertible)?]]
  ) throws {
    guard try db.tableExists(table) else { return }
    let present = Set(try db.columns(in: table).map(\.name))
    for row in rows {
      let columns = row.keys.filter(present.contains).sorted()
      let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
      let names = columns.map(\.quotedDatabaseIdentifier).joined(separator: ", ")
      try db.execute(
        sql: "INSERT INTO \(table.quotedDatabaseIdentifier) (\(names)) VALUES (\(placeholders))",
        arguments: StatementArguments(columns.map { row[$0] ?? nil }))
    }
  }
}
