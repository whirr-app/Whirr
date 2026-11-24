import GRDB

/// Cloud transport has no foreign keys to account or RSS catalogue rows. Losing either source
/// must not erase the durable work or record archives needed to reject stale callbacks.
enum PodcastCloudTransportMigration {
  static func migrate(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE podcastCloudTransport (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          namespace BLOB,
          nextGeneration INTEGER NOT NULL DEFAULT 0 CHECK (nextGeneration >= 0),
          bootstrapComplete INTEGER NOT NULL DEFAULT 0 CHECK (bootstrapComplete IN (0, 1)),
          engineState BLOB
        );
        INSERT INTO podcastCloudTransport (id) VALUES (1);
        CREATE TABLE podcastCloudOutbox (
          recordName TEXT PRIMARY KEY NOT NULL,
          generation INTEGER NOT NULL CHECK (generation > 0),
          namespace BLOB,
          operation TEXT NOT NULL CHECK (operation IN ('save', 'delete')),
          payload BLOB NOT NULL CHECK (length(payload) <= 65536)
        );
        CREATE TABLE podcastCloudSystemFields (
          namespace BLOB NOT NULL,
          recordName TEXT NOT NULL,
          generation INTEGER NOT NULL CHECK (generation > 0),
          archive BLOB NOT NULL,
          PRIMARY KEY (namespace, recordName)
        );
        """)
  }
}
