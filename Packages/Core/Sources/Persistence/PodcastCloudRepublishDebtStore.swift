import Foundation
import GRDB

/// One send the cloud still owes because the clock was quarantined when the mutation happened.
///
/// Only the identity is kept, not the value: the republish reads current local state, so it
/// publishes what is true now, not when the debt was recorded.
public struct PodcastCloudRepublishDebt: Sendable, Equatable {
  /// The record kind to republish. `saved` is the only producer today.
  public let recordKind: String
  public let subscriptionUUID: String
  public let identityKey: String
  public let alternateIdentityKey: String?
  public let guid: String?
  public let enclosureURL: String?
  public let recordedAt: Date

  public init(
    recordKind: String, subscriptionUUID: String, identityKey: String,
    alternateIdentityKey: String? = nil, guid: String? = nil, enclosureURL: String? = nil,
    recordedAt: Date
  ) {
    self.recordKind = recordKind
    self.subscriptionUUID = subscriptionUUID
    self.identityKey = identityKey
    self.alternateIdentityKey = alternateIdentityKey
    self.guid = guid
    self.enclosureURL = enclosureURL
    self.recordedAt = recordedAt
  }
}

/// `podcastCloudRepublishDebt`, written by the resolver inside the mutation's own transaction and
/// settled by the post-repair republish inside the transaction that enqueues the replacement, so a
/// debt is never both settled and unsent.
public enum PodcastCloudRepublishDebtStore {
  public static func record(in db: Database, _ debt: PodcastCloudRepublishDebt) throws {
    try db.execute(
      sql: """
        INSERT INTO podcastCloudRepublishDebt (
          recordKind, subscriptionUUID, identityKey, alternateIdentityKey, guid, enclosureURL,
          recordedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (recordKind, subscriptionUUID, identityKey) DO UPDATE SET
          alternateIdentityKey = excluded.alternateIdentityKey, guid = excluded.guid,
          enclosureURL = excluded.enclosureURL, recordedAt = excluded.recordedAt
        """,
      arguments: [
        debt.recordKind, debt.subscriptionUUID, debt.identityKey, debt.alternateIdentityKey,
        debt.guid, debt.enclosureURL, debt.recordedAt,
      ])
  }

  public static func all(in db: Database) throws -> [PodcastCloudRepublishDebt] {
    try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM podcastCloudRepublishDebt
        ORDER BY recordedAt, recordKind, subscriptionUUID, identityKey
        """
    ).map {
      PodcastCloudRepublishDebt(
        recordKind: $0["recordKind"], subscriptionUUID: $0["subscriptionUUID"],
        identityKey: $0["identityKey"], alternateIdentityKey: $0["alternateIdentityKey"],
        guid: $0["guid"], enclosureURL: $0["enclosureURL"], recordedAt: $0["recordedAt"])
    }
  }

  public static func settle(in db: Database, _ debt: PodcastCloudRepublishDebt) throws {
    try db.execute(
      sql: """
        DELETE FROM podcastCloudRepublishDebt
        WHERE recordKind = ? AND subscriptionUUID = ? AND identityKey = ?
        """, arguments: [debt.recordKind, debt.subscriptionUUID, debt.identityKey])
  }
}
