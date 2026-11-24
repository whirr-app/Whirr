import Foundation

/// Directory- and file-level protection. The database may hold unsynced progress, so it stays in
/// backup while its protection class prevents access before first unlock. Enforcement exists only
/// on-device (iOS Data Protection); this seam lets `AppDatabase` apply and verify attributes
/// without callers (including macOS host tests) depending on that. Mirrors the `SecItemClient`
/// seam ABSApi uses for the Keychain.
public protocol FileAttributeApplying: Sendable {
  /// Called once, before SQLite creates the database file, so files created later inside the
  /// directory (including the `-wal`/`-shm` sidecars) inherit the protection class.
  func protectDirectory(at directoryURL: URL) throws

  /// Applies `completeUntilFirstUserAuthentication` protection and confirms the main database file
  /// and every existing sidecar is not excluded from backup. Called again after writes (one may
  /// first create a sidecar), but only until every artifact exists
  /// (`AppDatabase.protectArtifactsIfNeeded`): each call is several filesystem round trips per
  /// artifact on device.
  func protectDatabaseArtifacts(at databaseURL: URL) throws

  /// The downloads root gets the database's protection class but is excluded from backup (media is
  /// large and re-fetchable). Called once, before any file is written, so later files inherit the
  /// class.
  func protectDownloadsRoot(at directoryURL: URL) throws

  /// Applies and verifies protection and backup exclusion for one just-completed download file.
  /// Called after each file is moved into place.
  func protectDownloadedFile(at fileURL: URL) throws
}

/// The on-disk files one SQLite WAL database is made of. The single source of truth for that
/// list: `AppDatabase` uses it to know when every artifact has been accounted for, and
/// `POSIXFileAttributeApplier` uses it to know what to protect.
public enum DatabaseArtifacts {
  public static func urls(for databaseURL: URL) -> [URL] {
    let base = databaseURL.path
    return [databaseURL, URL(fileURLWithPath: base + "-wal"), URL(fileURLWithPath: base + "-shm")]
  }
}

public enum FileAttributeError: Error, Sendable, Equatable {
  case protectionNotApplied(path: String)
  case excludedFromBackup(path: String)
  case notExcludedFromBackup(path: String)
}
