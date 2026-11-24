import Foundation
import GRDB
import Synchronization

/// Wraps the local SQLite store. `DatabaseWriter` is GRDB's common protocol for both a
/// `DatabasePool` (on-disk, WAL, used in production) and a `DatabaseQueue` (in-memory, used in
/// tests), so callers never need to know which one they hold.
///
/// The `DatabaseMigrator` here registers the v1 schema (SchemaV1.swift). Foreign keys are
/// enforced on every connection (`PRAGMA foreign_keys = ON`). The on-disk path protects its
/// directory before SQLite creates any file, then applies/verifies file protection and backup
/// inclusion on the main file and every existing sidecar, repeating after a write (which may
/// first create a sidecar) until every artifact exists.
public final class AppDatabase: Sendable {
  public let dbWriter: any DatabaseWriter
  private let fileAttributes: FileAttributeApplying?
  private let databaseURL: URL?
  /// Set once every artifact exists (see `protectArtifactsIfNeeded`).
  private let allArtifactsProtected = Mutex(false)

  /// In-memory store: fast, no files, so there is nothing for the protection seam to do.
  ///
  /// Replaying every migration costs more than a typical test does with the store, so the schema
  /// is migrated once per process into a template and each call copies it with SQLite's backup
  /// API. The page-for-page copy carries the migration ledger.
  public static func inMemory() throws -> AppDatabase {
    let queue = try DatabaseQueue(configuration: configuration)
    try migratedTemplate.get().backup(to: queue)
    return AppDatabase(dbWriter: queue, fileAttributes: nil, databaseURL: nil)
  }

  private static let migratedTemplate = Result<DatabaseQueue, any Error> {
    let queue = try DatabaseQueue(configuration: configuration)
    try migrator.migrate(queue)
    return queue
  }

  /// On-disk store at `url`. Protects the containing directory before opening (so later-created
  /// `-wal`/`-shm` sidecars inherit protection), opens a WAL `DatabasePool`, then applies/verifies
  /// the same attributes on the main file and any sidecar that already exists.
  public static func onDisk(at url: URL, fileAttributes: FileAttributeApplying) throws -> AppDatabase {
    try fileAttributes.protectDirectory(at: url.deletingLastPathComponent())
    let pool = try DatabasePool(path: url.path, configuration: configuration)
    let database = AppDatabase(dbWriter: pool, fileAttributes: fileAttributes, databaseURL: url)
    try database.protectArtifactsIfNeeded()
    try database.migrate()
    return database
  }

  private init(dbWriter: any DatabaseWriter, fileAttributes: FileAttributeApplying?, databaseURL: URL?) {
    self.dbWriter = dbWriter
    self.fileAttributes = fileAttributes
    self.databaseURL = databaseURL
  }

  private static var configuration: Configuration {
    var configuration = Configuration()
    // `AppEnvironment` is rebuilt after login/logout while work owned by the previous
    // environment may still be committing. Give those short writes time to finish instead of
    // surfacing SQLITE_BUSY from BEGIN IMMEDIATE TRANSACTION.
    configuration.busyMode = .timeout(5)
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      // The FTS5 triggers call `searchFold` (and, from `v83`, `searchPlainText`) on whichever
      // connection performs the write, so the functions are registered here rather than only
      // where `DefaultSearchReading` queries from. `searchCanonical` (shared with Library quick
      // filtering) and the query-only `searchFuzzyDistance` are registered on every pooled read
      // connection for Search's fallbacks.
      SchemaV1.registerSearchFunctions(db)
    }
    return configuration
  }

  /// The v1 schema migration (SchemaV1.swift). Re-running an already-applied migrator is a
  /// cheap no-op (GRDB tracks applied identifiers), so every construction path can call it
  /// unconditionally.
  private static var migrator: DatabaseMigrator { SchemaV1.migrator() }

  private func migrate() throws {
    try Self.migrator.migrate(dbWriter)
  }

  @discardableResult
  public func write<T>(_ updates: @Sendable (Database) throws -> T) throws -> T {
    let result = try dbWriter.write(updates)
    try protectArtifactsIfNeeded()
    return result
  }

  /// Suspends the calling task while GRDB executes `updates` on its writer executor.
  ///
  /// Async orchestration must use this entry point instead of `write`: the synchronous GRDB
  /// overload bottoms out in `dispatch_sync`, which can pin every Swift cooperative-pool thread
  /// when many independent databases are active in parallel.
  @discardableResult
  public func writeAsync<T: Sendable>(
    _ updates: @Sendable (Database) throws -> T
  ) async throws -> T {
    let result = try await dbWriter.write(updates)
    try protectArtifactsIfNeeded()
    return result
  }

  public func read<T>(_ value: @Sendable (Database) throws -> T) throws -> T {
    try dbWriter.read(value)
  }

  /// Suspends the calling task while GRDB executes `value` on its reader executor.
  public func readAsync<T: Sendable>(
    _ value: @Sendable (Database) throws -> T
  ) async throws -> T {
    try await dbWriter.read(value)
  }

  /// A post-write pass can only discover a sidecar that did not exist yet: `protectDirectory`
  /// (run before SQLite created anything) already gives later-created files their protection
  /// class. It is also costly on device (per artifact, a protection-class write, an
  /// extended-attribute write and two stats, and a first sync commits one transaction per page
  /// plus one per item with server progress). Once every artifact exists this retires itself
  /// permanently, since the open `DatabasePool` keeps the sidecars in place.
  private func protectArtifactsIfNeeded() throws {
    guard let fileAttributes, let databaseURL else { return }
    guard allArtifactsProtected.withLock({ $0 }) == false else { return }
    try fileAttributes.protectDatabaseArtifacts(at: databaseURL)
    let everyArtifactExists = DatabaseArtifacts.urls(for: databaseURL).allSatisfy {
      FileManager.default.fileExists(atPath: $0.path)
    }
    if everyArtifactExists {
      allArtifactsProtected.withLock { $0 = true }
    }
  }
}
