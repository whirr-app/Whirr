import Foundation
import GRDB
import Synchronization

extension SchemaV1 {
  // MARK: - v4: converging a drifted store

  /// The last migration defining "the shape a fresh store has". `healSchemaDrift` measures a store
  /// against a scratch database migrated this far, so it agrees with the `create*` helpers in
  /// `SchemaV1.swift` and does not pre-apply later migrations.
  private static let currentShapeReference = "v3"

  enum SchemaHealError: Error, Equatable {
    /// A `NOT NULL` column with no default was added to an existing table by an in-place
    /// amendment, and `legacyColumnFallbacks` has no reviewed value for rows that predate it.
    /// Fatal: inventing a value for a column the app trusts is worse than refusing.
    case noValueForLegacyRows(table: String, column: String)
  }

  private struct SchemaObject: Sendable {
    var type: String
    var name: String
    var tableName: String
    var sql: String
  }

  /// The reference shape is a pure function of the migrations in this file, so it is harvested once
  /// per process rather than once per store. Otherwise every `AppDatabase` construction (several
  /// hundred in a test run) would open and migrate a scratch database.
  private static let cachedCurrentShape = Mutex<[SchemaObject]?>(nil)

  /// Where `v4` may invent a value: a `NOT NULL`, no-default column that a later in-place
  /// amendment added to a table which already had rows. Keyed `table.column`.
  ///
  /// These are the `download` transfer columns, with inert values rather than plausible ones. A
  /// legacy row has no server file identity, so `serverFileIno` gets `legacy-<id>`: unique (the
  /// partial unique indexes hold) and plainly not a server `ino`. `expectedMimeType`,
  /// `fileDurationSeconds` and `expectedBytes` get empty/zero, so `DownloadFileStore`'s MIME,
  /// `Content-Length` and on-disk size checks fail closed for a legacy row.
  private static let legacyColumnFallbacks: [String: String] = [
    "download.serverFileIno": #"('legacy-' || "id")"#,
    "download.orderIndex": "0",
    "download.expectedMimeType": "''",
    "download.fileDurationSeconds": "0.0",
    "download.expectedBytes": "0",
  ]

  /// Columns a later amendment replaced, and how to carry the retired column's information into
  /// the new one instead of dropping it.
  ///
  /// `download.errorReason` was free text, replaced by the privacy-safe `errorCategory` enum. No
  /// shipped code wrote a known vocabulary into it, so only "there was an error" carries over, as
  /// `DownloadErrorCategory.unknown`. The retired column is dropped: keeping it would leave a
  /// healed store that never equals a fresh one.
  private static let retiredColumnMappings: [String: (legacy: String, expression: String)] = [
    "download.errorCategory": (
      "errorReason", #"CASE WHEN "errorReason" IS NOT NULL THEN 'unknown' ELSE NULL END"#
    )
  ]

  /// Converges a store carrying any earlier `v1` shape to the current one.
  ///
  /// Introspection-driven: stores created at different moments miss different subsets. The
  /// reference shape is read from a scratch database migrated through `currentShapeReference`, so
  /// it comes from the same `create*` helpers a fresh store uses.
  static func healSchemaDrift(_ db: Database) throws {
    let canonical = try currentShapeObjects()

    // 1. Tables. Missing ones are created from the reference SQL verbatim; changed ones are
    //    rebuilt, because a column added mid-list, a nullability tightened and a column retired
    //    are all beyond `ALTER TABLE`.
    let existing = try schemaObjects(db).reduce(into: [String: SchemaObject]()) { $0[$1.name] = $1 }
    for table in canonical where table.type == "table" {
      guard let current = existing[table.name] else {
        try db.execute(sql: table.sql)
        continue
      }
      if collapseWhitespace(current.sql) != collapseWhitespace(table.sql) {
        try rebuild(db, to: table)
      }
    }

    // 2. Indexes, after every table has its final shape (an index can reference a column only
    //    step 1 just restored). One with the right name but the wrong definition is replaced.
    let actual = try schemaObjects(db).reduce(into: [String: SchemaObject]()) { $0[$1.name] = $1 }
    for index in canonical where index.type == "index" {
      if let current = actual[index.name] {
        guard collapseWhitespace(current.sql) != collapseWhitespace(index.sql) else { continue }
        try db.execute(sql: "DROP INDEX \(index.name.quotedDatabaseIdentifier)")
      }
      try db.execute(sql: index.sql)
    }

    // 3. Indexes a rebuild did not already remove and the current shape no longer has. Indexes
    //    carry no data, so dropping is safe. A stray table is left alone: guessing that user data
    //    is disposable is not this migration's call.
    let canonicalNames = Set(canonical.map(\.name))
    let canonicalTables = Set(canonical.filter { $0.type == "table" }.map(\.name))
    for stray in try schemaObjects(db)
    where stray.type == "index" && canonicalTables.contains(stray.tableName)
      && canonicalNames.contains(stray.name) == false
    {
      try db.execute(sql: "DROP INDEX \(stray.name.quotedDatabaseIdentifier)")
    }
  }

  /// The shape a fresh store has, harvested from a scratch in-memory database rather than
  /// restated here.
  private static func currentShapeObjects() throws -> [SchemaObject] {
    if let cached = cachedCurrentShape.withLock({ $0 }) { return cached }
    let reference = try DatabaseQueue()
    try migrator().migrate(reference, upTo: currentShapeReference)
    let objects = try reference.read { db in try schemaObjects(db) }
    cachedCurrentShape.withLock { $0 = objects }
    return objects
  }

  /// Every migration-created object, in creation order (`sqlite_master`'s rowid). SQLite's own
  /// bookkeeping (implicit `UNIQUE`/primary-key indexes, `sqlite_sequence`) has a NULL `sql` or a
  /// reserved name and is never ours to recreate.
  private static func schemaObjects(_ db: Database) throws -> [SchemaObject] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT type, name, tbl_name, sql FROM sqlite_master
        WHERE sql IS NOT NULL AND name NOT LIKE 'sqlite_%' AND name <> 'grdb_migrations'
        ORDER BY rowid
        """
    ).map {
      SchemaObject(type: $0["type"], name: $0["name"], tableName: $0["tbl_name"], sql: $0["sql"])
    }
  }

  /// SQLite's documented table-rebuild procedure (`lang_altertable.html#otheralter`), which GRDB's
  /// default `.deferred` migration mode sets up: `PRAGMA foreign_keys = OFF` inside a transaction,
  /// then `PRAGMA foreign_key_check` before committing. With enforcement off, renaming the old
  /// table does not rewrite `REFERENCES` clauses in tables pointing at it and dropping it does not
  /// cascade into them.
  ///
  /// The new table is created under its real name, not built beside and renamed, because
  /// `ALTER TABLE ... RENAME` leaves index names untouched. Every row's `id` is carried across,
  /// keeping child foreign keys valid.
  private static func rebuild(_ db: Database, to canonical: SchemaObject) throws {
    let table = canonical.name
    let legacyTable = "\(table)_v4Drifted"
    let legacyColumns = try db.columns(in: table).reduce(into: [String: ColumnInfo]()) {
      $0[$1.name] = $1
    }
    let staleIndexes = try String.fetchAll(
      db,
      sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL",
      arguments: [table])

    try db.execute(
      sql: """
        ALTER TABLE \(table.quotedDatabaseIdentifier) \
        RENAME TO \(legacyTable.quotedDatabaseIdentifier)
        """)
    for index in staleIndexes {
      try db.execute(sql: "DROP INDEX \(index.quotedDatabaseIdentifier)")
    }
    try db.execute(sql: canonical.sql)
    db.clearSchemaCache()

    let targetColumns = try db.columns(in: table)
    let names = targetColumns.map(\.name.quotedDatabaseIdentifier).joined(separator: ", ")
    let values =
      try targetColumns
      .map { try carriedValue(table: table, column: $0, legacyColumns: legacyColumns) }
      .joined(separator: ", ")
    try db.execute(
      sql: """
        INSERT INTO \(table.quotedDatabaseIdentifier) (\(names)) \
        SELECT \(values) FROM \(legacyTable.quotedDatabaseIdentifier)
        """)
    try db.execute(sql: "DROP TABLE \(legacyTable.quotedDatabaseIdentifier)")
    db.clearSchemaCache()
  }

  /// What a rebuilt table's column reads from the drifted one it replaces.
  private static func carriedValue(
    table: String, column: ColumnInfo, legacyColumns: [String: ColumnInfo]
  ) throws -> String {
    let quoted = column.name.quotedDatabaseIdentifier
    if let legacy = legacyColumns[column.name] {
      guard column.isNotNull, legacy.isNotNull == false else { return quoted }
      // A nullability an amendment tightened: existing NULLs need somewhere to land.
      return "COALESCE(\(quoted), \(try fallback(table: table, column: column)))"
    }
    if let mapping = retiredColumnMappings["\(table).\(column.name)"],
      legacyColumns[mapping.legacy] != nil
    {
      return mapping.expression
    }
    if column.isNotNull == false { return "NULL" }
    if let defaultValue = column.defaultValueSQL { return defaultValue }
    return try fallback(table: table, column: column)
  }

  private static func fallback(table: String, column: ColumnInfo) throws -> String {
    guard let fallback = legacyColumnFallbacks["\(table).\(column.name)"] else {
      throw SchemaHealError.noValueForLegacyRows(table: table, column: column.name)
    }
    return fallback
  }

  private static func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}
