import GRDB

/// Identity and clock substrate. None of these tables has a foreign key to `rssFeed`,
/// `rssEpisode` or `account`: `RSSFeedStore.unsubscribe` cascades every child, and a
/// subscription's sync UUID, follow generation and unfollow stamp must outlive that. The registry
/// entry is the durable identity; the catalogue row is a local projection.
enum PodcastCloudRegistryMigration {
  /// v69: the accepted record itself, beside its stamp. One stamp cannot order every register:
  /// episode state merges on its explicit epoch before its write stamp, and a subscription record
  /// carries two registers that merge independently. Admission merges against the accepted value,
  /// so the value is kept. Nullable, because a row written before this version, or by a caller
  /// that only knows the stamp, has none; admission then falls back to comparing stamps.
  static func addAcceptedPayload(_ db: Database) throws {
    try db.execute(sql: "ALTER TABLE podcastCloudEntityStamp ADD COLUMN payload BLOB")
  }

  static func migrate(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE podcastCloudSubscriptionRegistry (
          subscriptionUUID TEXT PRIMARY KEY NOT NULL,
          fingerprint TEXT NOT NULL,
          normalizedURL TEXT NOT NULL,
          canonicalizationVersion INTEGER NOT NULL,
          generationUUID TEXT NOT NULL,
          isFollowed INTEGER NOT NULL CHECK (isFollowed IN (0, 1)),
          followPhysicalMilliseconds INTEGER NOT NULL,
          followLogicalCounter INTEGER NOT NULL,
          followInstallationUUID TEXT NOT NULL,
          followMutationUUID TEXT NOT NULL
        );
        CREATE UNIQUE INDEX index_podcastCloudSubscriptionRegistry_on_fingerprint
          ON podcastCloudSubscriptionRegistry (fingerprint);
        """)

    // The whole of `PodcastCloudClockState`, one row. Minted lazily, not by this migration: a
    // restored device must not adopt the installation identity of the device the backup came from
    // (ADR 0009), and a migration cannot tell a restore from a fresh install.
    try db.execute(
      sql: """
        CREATE TABLE podcastCloudInstallation (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          installationUUID TEXT NOT NULL CHECK (length(installationUUID) = 36),
          physicalMilliseconds INTEGER NOT NULL DEFAULT 0 CHECK (physicalMilliseconds >= 0),
          logicalCounter INTEGER NOT NULL DEFAULT 0 CHECK (logicalCounter >= 0),
          anchorServerMilliseconds INTEGER
            CHECK (anchorServerMilliseconds IS NULL OR anchorServerMilliseconds >= 0),
          lastAdmittedPhysicalMilliseconds INTEGER NOT NULL DEFAULT 0
            CHECK (lastAdmittedPhysicalMilliseconds >= 0),
          lastAdmittedLogicalCounter INTEGER NOT NULL DEFAULT 0
            CHECK (lastAdmittedLogicalCounter >= 0),
          repairRequired INTEGER NOT NULL DEFAULT 0 CHECK (repairRequired IN (0, 1)),
          -- `PodcastCloudClockState`'s cross-field guard, restated because `Persistence` cannot
          -- import `SyncEngine`: a clock may never sit behind the last stamp it admitted.
          CHECK (
            physicalMilliseconds > lastAdmittedPhysicalMilliseconds
            OR (physicalMilliseconds = lastAdmittedPhysicalMilliseconds
                AND logicalCounter >= lastAdmittedLogicalCounter)
          )
        );
        """)

    // The last stamp this device accepted per entity, not the last it generated: a later merge
    // compares against an admitted remote write, and that must survive engine-state loss because
    // that state is a discardable cache.
    try db.execute(
      sql: """
        CREATE TABLE podcastCloudEntityStamp (
          recordName TEXT PRIMARY KEY NOT NULL,
          physicalMilliseconds INTEGER NOT NULL CHECK (physicalMilliseconds >= 0),
          logicalCounter INTEGER NOT NULL CHECK (logicalCounter >= 0),
          installationUUID TEXT NOT NULL,
          mutationUUID TEXT NOT NULL
        );
        """)

    // Remote episode state that arrived before the identity it refers to could be resolved. Held
    // as the opaque encoded payload so this table never has to understand the record layout, and
    // bounded by retention rather than growing with the publisher's whole back catalogue.
    try db.execute(
      sql: """
        CREATE TABLE podcastCloudUnresolvedEpisodeState (
          recordName TEXT PRIMARY KEY NOT NULL,
          subscriptionUUID TEXT NOT NULL,
          generationUUID TEXT NOT NULL,
          episodeDigest TEXT NOT NULL,
          payload BLOB NOT NULL CHECK (length(payload) <= 65536),
          receivedAt DATETIME NOT NULL
        );
        CREATE INDEX index_podcastCloudUnresolvedEpisodeState_on_generation
          ON podcastCloudUnresolvedEpisodeState (subscriptionUUID, generationUUID);
        """)
  }
}
