import GRDB

/// v105: the Watch downloads an offered episode's enclosure itself (ADR 0020 Decision 1), so the
/// two states that described the phone's own file transfer are gone from `RSSWatchCopyState`.
///
/// v104 is frozen, so its `CHECK` still admits `waitingForDownload` and `delivering`, and a store
/// that ran a build from before ADR 0020 can hold rows in them. `DatabaseValueConvertible` decodes
/// a state by raw value and yields nothing for a value the enum no longer has, so every read of the
/// table would fail until the rows move. Each becomes `wanted` here: an offer member the publisher
/// sends again, whose outcome the Watch's own inventory decides.
enum RSSWatchCopyLegacyStateMigration {
  static func migrate(_ db: Database) throws {
    let legacyRows =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM rssWatchCopy
          WHERE state IN ('waitingForDownload', 'delivering')
          """) ?? 0
    guard legacyRows > 0 else { return }

    try db.execute(
      sql: """
        UPDATE rssWatchCopy
        SET state = 'wanted', sourceBytes = NULL, failedAt = NULL
        WHERE state IN ('waitingForDownload', 'delivering')
        """)
    // The Watch ignores an offer at or below the generation it last applied, so the generation
    // must move on for the next offer to re-list the rewritten rows, as a removal's does.
    try db.execute(sql: "UPDATE rssWatchCopySet SET generation = generation + 1 WHERE id = 1")
  }
}
