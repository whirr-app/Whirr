import GRDB

/// One optional reader-preferences payload per account (`v20`). Persistence keeps
/// the payload opaque: `ReaderCore` owns the `ReaderPreferences` type and its Codable defaults,
/// while this record only enforces the account scope and durable JSON text.
public struct ReaderPreferencesRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "readerPreferences"

  public var accountId: Int64
  public var preferencesJSON: String

  public init(accountId: Int64, preferencesJSON: String) {
    self.accountId = accountId
    self.preferencesJSON = preferencesJSON
  }
}
