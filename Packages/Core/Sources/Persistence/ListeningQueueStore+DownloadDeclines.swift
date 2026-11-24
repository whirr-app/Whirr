import Foundation
import GRDB

/// Up Next entries whose download the listener removed by hand. The flag is a
/// column on the queue row, so it ends with the entry. None of these writes moves the queue
/// revision: the order is unchanged, and a bump would make a pending Clear's Undo token stale.
extension ListeningQueueStore: ListeningQueueDownloadDeclineReading {
  /// Flags the entries a hand removal named, in the download intents' spelling: a server item id
  /// or `rss:<feedId>`, with or without an episode. A server item with no episode covers the
  /// audiobook or every queued episode of the show; `itemID` nil covers every entry. Native rows
  /// carry no account, so they are device-wide, as `clear()` treats them.
  public func declineDownloads(itemID: String?, episodeID: String?, at date: Date) async throws {
    let target = DeclineTarget.removal(itemID: itemID, episodeID: episodeID)
    try await database.writeAsync { db in
      try Self.setDownloadDeclined(db, accountId: accountId, target: target, at: date)
    }
  }

  /// Flags the entries "Reclaim removed episodes" empties, by the coordinator's own predicate.
  public func declineTombstonedDownloads(at date: Date) async throws {
    try await database.writeAsync { db in
      try Self.setDownloadDeclined(db, accountId: accountId, target: .tombstoned, at: date)
    }
  }

  /// A hand download of the entry. With no episode it clears an audiobook only: the coordinator
  /// refuses a whole-show request, so it never stands for a show's episodes.
  public func clearDownloadDecline(itemID: String, episodeID: String?) async throws {
    guard let target = DeclineTarget.handDownload(itemID: itemID, episodeID: episodeID) else {
      return
    }
    try await database.writeAsync { db in
      for (table, condition) in Self.conditions(for: target, accountId: accountId) {
        try db.execute(
          sql: """
            UPDATE \(table) SET downloadDeclinedAt = NULL
            WHERE downloadDeclinedAt IS NOT NULL AND \(condition.sql)
            """,
          arguments: condition.arguments)
      }
    }
  }

  public func isDownloadDeclined(_ identity: ListeningIdentity) async throws -> Bool {
    try await database.readAsync { db in
      try Self.downloadDeclinedAt(db, accountId: accountId, identity: identity) != nil
    }
  }

  // MARK: - Shared with clear and restore

  static func setDownloadDeclined(
    _ db: Database, accountId: Int64?, target: DeclineTarget, at date: Date
  ) throws {
    for (table, condition) in conditions(for: target, accountId: accountId) {
      try db.execute(
        sql: """
          UPDATE \(table) SET downloadDeclinedAt = ?
          WHERE downloadDeclinedAt IS NULL AND \(condition.sql)
          """,
        arguments: [date] + condition.arguments)
    }
  }

  static func downloadDeclinedAt(
    _ db: Database, accountId: Int64?, identity: ListeningIdentity
  ) throws -> Date? {
    for (table, condition) in conditions(for: DeclineTarget(identity), accountId: accountId) {
      let declinedAt = try Date.fetchOne(
        db,
        sql: "SELECT downloadDeclinedAt FROM \(table) WHERE \(condition.sql)",
        arguments: condition.arguments)
      if let declinedAt { return declinedAt }
    }
    return nil
  }

  /// The `WHERE` clause naming the target's rows in each queue table it can touch.
  private static func conditions(
    for target: DeclineTarget, accountId: Int64?
  ) -> [(table: String, condition: (sql: String, arguments: StatementArguments))] {
    let server = "listeningQueueEntry"
    let native = "rssListeningQueueEntry"
    let serverItem = "itemId IN (SELECT id FROM item WHERE accountId = ? AND serverItemId = ?)"
    switch target {
    case .everything:
      return [(server, ("accountId = ?", [accountId])), (native, ("1", []))]
    case .serverItem(let itemID):
      return [(server, ("accountId = ? AND \(serverItem)", [accountId, accountId, itemID]))]
    case .audiobook(let itemID):
      return [
        (
          server,
          (
            "accountId = ? AND podcastEpisodeId IS NULL AND \(serverItem)",
            [accountId, accountId, itemID]
          )
        )
      ]
    case .serverEpisode(let itemID, let episodeID):
      return [
        (
          server,
          (
            """
            accountId = ? AND podcastEpisodeId IN (
              SELECT episode.id FROM podcastEpisode AS episode
              JOIN item ON item.id = episode.itemId AND item.accountId = episode.accountId
              WHERE episode.accountId = ? AND item.serverItemId = ?
                AND episode.serverEpisodeId = ?)
            """,
            [accountId, accountId, itemID, episodeID]
          )
        )
      ]
    case .nativeFeed(let feedID):
      return [(native, ("rssEpisodeId IN (SELECT id FROM rssEpisode WHERE feedId = ?)", [feedID]))]
    case .nativeEpisode(let feedID, let episodeID):
      return [
        (
          native,
          (
            "rssEpisodeId IN (SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?)",
            [feedID, episodeID]
          )
        )
      ]
    case .tombstoned:
      return [
        (
          server,
          (
            """
            accountId = ? AND podcastEpisodeId IN (
              SELECT episode.id FROM podcastEpisode AS episode
              WHERE \(EpisodeTombstoneSQL.server))
            """,
            [accountId]
          )
        ),
        (
          native,
          (
            """
            rssEpisodeId IN (
              SELECT episode.id FROM rssEpisode AS episode
              JOIN rssFeed AS feed ON feed.id = episode.feedId
              WHERE \(EpisodeTombstoneSQL.rss))
            """,
            []
          )
        ),
      ]
    }
  }
}

/// Which Up Next entries a decline or a clear names.
enum DeclineTarget: Sendable, Equatable {
  case everything
  /// The audiobook's entry, or every queued episode of the show.
  case serverItem(String)
  case audiobook(String)
  case serverEpisode(itemID: String, episodeID: String)
  case nativeFeed(Int64)
  case nativeEpisode(feedID: Int64, episodeID: String)
  case tombstoned

  init(_ identity: ListeningIdentity) {
    switch identity.source {
    case .audiobook(let itemID): self = .audiobook(itemID)
    case .podcastEpisode(let itemID, let episodeID):
      self = .serverEpisode(itemID: itemID, episodeID: episodeID)
    case .rssEpisode(let feedID, let episodeID):
      self = .nativeEpisode(feedID: feedID, episodeID: episodeID)
    }
  }

  static func removal(itemID: String?, episodeID: String?) -> Self {
    guard let itemID else { return .everything }
    if let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId {
      return episodeID.map { .nativeEpisode(feedID: feedID, episodeID: $0) } ?? .nativeFeed(feedID)
    }
    return episodeID.map { .serverEpisode(itemID: itemID, episodeID: $0) } ?? .serverItem(itemID)
  }

  static func handDownload(itemID: String, episodeID: String?) -> Self? {
    switch removal(itemID: itemID, episodeID: episodeID) {
    case .serverItem(let itemID): .audiobook(itemID)
    case .nativeFeed: nil
    case let target: target
    }
  }
}
