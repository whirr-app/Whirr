import Foundation

/// Opaque JSON access to one account's reader preferences. `ReaderCore` remains the owner of
/// encoding, decoding, unknown-field tolerance, and initial defaults; Persistence only stores the
/// bounded text and never imports that higher-level target.
public protocol ReaderPreferencesStoring: Sendable {
  /// Returns the stored payload, or `nil` before this account has saved preferences.
  func fetchPreferencesJSON() async throws -> String?

  /// Replaces this account's one payload atomically.
  func writePreferencesJSON(_ preferencesJSON: String) async throws
}

extension ReaderPreferencesStoring {
  /// Supplies a reader-owned encoded default when the account has no row. This does not create a
  /// row, so a fresh account remains distinguishable from one that explicitly saved its defaults.
  public func fetchPreferencesJSON(defaultingTo defaultJSON: String) async throws -> String {
    try await fetchPreferencesJSON() ?? defaultJSON
  }
}

public enum ReaderPreferencesStoreError: Error, Equatable, Sendable {
  case preferencesJSONTooLarge
}

/// The account-scoped reader-preferences store (`v20`). The payload is opaque JSON because
/// `Persistence` cannot depend upward on `ReaderCore`; all mutations use `writeAsync` so callers
/// on cooperative concurrency threads never enter GRDB's synchronous writer path.
public struct ReaderPreferencesStore: ReaderPreferencesStoring, Sendable {
  /// A preferences payload is local value state, not an unbounded document store.
  public static let maximumPreferencesJSONBytes = 64 * 1024

  private let database: AppDatabase
  private let accountId: Int64

  public init(database: AppDatabase, accountId: Int64) {
    self.database = database
    self.accountId = accountId
  }

  public func fetchPreferencesJSON() async throws -> String? {
    try await database.readAsync { db in
      try ReaderPreferencesRecord.fetchOne(db, key: accountId)?.preferencesJSON
    }
  }

  public func writePreferencesJSON(_ preferencesJSON: String) async throws {
    guard preferencesJSON.utf8.count <= Self.maximumPreferencesJSONBytes else {
      throw ReaderPreferencesStoreError.preferencesJSONTooLarge
    }

    try await database.writeAsync { db in
      let record = ReaderPreferencesRecord(
        accountId: accountId, preferencesJSON: preferencesJSON)
      try record.save(db)
    }
  }
}
