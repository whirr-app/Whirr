import GRDB

/// The account identity as the server-save lifecycle sees it. Carries no raw server URL or user
/// id: the fingerprint is the opaque value the durable attempt fence records
/// (`AccountRecord.serverIdentityFingerprint`), so equality matches the coordinator's fence.
/// Same-account reauthentication is the same identity; a replacement on the same server is a
/// different one.
public struct AccountIdentity: Sendable, Equatable, Hashable {
  public let id: Int64
  public let clientUUID: String
  public let serverIdentityFingerprint: String

  public init(id: Int64, clientUUID: String, serverIdentityFingerprint: String) {
    self.id = id
    self.clientUUID = clientUUID
    self.serverIdentityFingerprint = serverIdentityFingerprint
  }

  /// Nil when the record has no row id.
  public init?(record: AccountRecord) {
    guard let id = record.id else { return nil }
    self.init(
      id: id,
      clientUUID: record.clientUUID,
      serverIdentityFingerprint:
        record.serverIdentityFingerprint)
  }
}

public protocol AccountIdentityReading: Sendable {
  /// Yields the current identity first, then every change. Consecutive equal values are not
  /// repeated.
  func observeAccountIdentity() -> AsyncStream<AccountIdentity?>
}

/// Never yields; finishes immediately. Unwired compositions see no lifecycle event.
public struct NoOpAccountIdentityReading: AccountIdentityReading, Sendable {
  public init() {}

  public func observeAccountIdentity() -> AsyncStream<AccountIdentity?> {
    AsyncStream { $0.finish() }
  }
}

/// GRDB `ValueObservation` over the single account row, bridged through `ObservationBridge`.
public struct DefaultAccountIdentityReading: AccountIdentityReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func observeAccountIdentity() -> AsyncStream<AccountIdentity?> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          guard let record = try AccountRecord.order(Column("id")).fetchOne(db) else {
            return nil
          }
          return AccountIdentity(record: record)
        }
        .removeDuplicates())
  }
}
