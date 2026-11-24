import GRDB

/// Durable sync state. Like the transport tables it extends, none of this carries a
/// foreign key to account or RSS catalogue rows.
enum PodcastCloudSyncStateMigration {
  static func migrate(_ db: Database) throws {
    // `zoneEstablished` separates first-enable `zoneNotFound` (create the zone) from a zone this
    // namespace had that is now gone (silent recreation is forbidden). `activate` clears it when
    // the namespace changes. `status` is an opaque `SyncEngine` token; `statusRetryAfter` is
    // display-only, as the engine owns retry scheduling.
    try db.execute(
      sql: """
        ALTER TABLE podcastCloudTransport
          ADD COLUMN zoneEstablished INTEGER NOT NULL DEFAULT 0 CHECK (zoneEstablished IN (0, 1));
        ALTER TABLE podcastCloudTransport ADD COLUMN status TEXT;
        ALTER TABLE podcastCloudTransport ADD COLUMN statusRetryAfter DATETIME;
        """)

    // Records held as `Sync needs attention`: malformed, oversize, an unmergeable conflict, a
    // plaintext violation, a quarantined stamp. Categories only, never payloads or titles. An
    // outbox row is held at one generation, so a newer local mutation of the same record is
    // eligible to send again; a held fetched record has no generation.
    try db.execute(
      sql: """
        CREATE TABLE podcastCloudHeldRecord (
          namespace BLOB NOT NULL,
          recordName TEXT NOT NULL,
          generation INTEGER,
          category TEXT NOT NULL,
          observedAt DATETIME NOT NULL,
          PRIMARY KEY (namespace, recordName)
        );
        """)

    // Sends skipped because the clock was quarantined, kept so the post-repair republish knows
    // exactly what to re-stamp. Keyed by episode identity rather than a row id: the episode row
    // can be pruned by a feed refresh while the debt is outstanding.
    try db.execute(
      sql: """
        CREATE TABLE podcastCloudRepublishDebt (
          recordKind TEXT NOT NULL CHECK (recordKind IN ('saved')),
          subscriptionUUID TEXT NOT NULL,
          identityKey TEXT NOT NULL,
          alternateIdentityKey TEXT,
          guid TEXT,
          enclosureURL TEXT,
          recordedAt DATETIME NOT NULL,
          PRIMARY KEY (recordKind, subscriptionUUID, identityKey)
        );
        """)
  }
}
