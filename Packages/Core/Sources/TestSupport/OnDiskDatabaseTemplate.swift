import Foundation
import GRDB
import Persistence

/// How a fixture prepares a database file that does not exist yet.
public enum OnDiskDatabaseSeeding: Sendable {
  /// Clone the process's migrated template, so `AppDatabase.onDisk` finds every migration already
  /// applied. The default: replaying all migrations costs a fresh store about 150–250 ms of CPU.
  case fromTemplate
  /// Leave the path empty so `AppDatabase.onDisk` runs the production migrate-from-empty path,
  /// including the file-protection order around SQLite's first file. For tests whose subject is
  /// that path.
  case migrateFromEmpty
}

/// One on-disk store per test process, migrated from empty through the real `AppDatabase.onDisk`,
/// that fresh fixture stores are cloned from.
///
/// The template is written once, before any clone is taken, and never written again, so clones
/// cannot see each other's rows. It is checkpointed and closed before the first clone, so its main
/// file alone is the whole store. The file stays in the temporary directory after the process
/// exits: the test helper runs no exit hooks, and the system clears that directory.
public enum OnDiskDatabaseTemplate {

  /// False when `WHIRR_TEST_ONDISK_SEEDING=off`, which makes every fresh store migrate from empty
  /// so one test binary can be measured with seeding on and off.
  public static let isEnabled =
    ProcessInfo.processInfo.environment["WHIRR_TEST_ONDISK_SEEDING"] != "off"

  /// Clones the template to `url` when no file exists there and its directory does, and reports
  /// whether it did. An existing file is a reopen and keeps its rows; a missing directory is left
  /// for `AppDatabase.onDisk` to report.
  @discardableResult
  public static func seedIfAbsent(at url: URL) throws -> Bool {
    let fileManager = FileManager.default
    guard isEnabled, fileManager.fileExists(atPath: url.path) == false,
      fileManager.fileExists(atPath: url.deletingLastPathComponent().path)
    else { return false }
    try fileManager.copyItem(at: templateURL.get(), to: url)
    return true
  }

  /// The template's main file. Built on first use.
  public static func url() throws -> URL {
    try templateURL.get()
  }

  private static let templateURL: Result<URL, any Error> = Result {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("whirr-ondisk-template-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("template.sqlite")
    let database = try AppDatabase.onDisk(at: url, fileAttributes: InertFileAttributes())
    try database.dbWriter.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }
    try database.dbWriter.close()
    return url
  }
}
