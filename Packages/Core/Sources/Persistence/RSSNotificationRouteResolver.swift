import Foundation
import GRDB

public enum RSSNotificationResolvedDestination: Sendable, Equatable {
  case episode(feedID: Int64, identityKey: String)
  case show(feedID: Int64)
  case latest
  case podcastsRoot
}

public struct RSSNotificationRouteResolver: Sendable {
  private let database: AppDatabase
  public init(database: AppDatabase) { self.database = database }

  public func resolve(_ route: RSSNotificationRoute) async throws
    -> RSSNotificationResolvedDestination
  {
    try await database.readAsync { db in
      switch route {
      case .episode(let feedID, let identityKey):
        guard try feedExists(db, feedID: feedID) else { return .podcastsRoot }
        let episodeExists =
          try Int64.fetchOne(
            db,
            sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
            arguments: [feedID, identityKey]) != nil
        return episodeExists
          ? .episode(feedID: feedID, identityKey: identityKey) : .show(feedID: feedID)
      case .show(let feedID):
        return try feedExists(db, feedID: feedID) ? .show(feedID: feedID) : .podcastsRoot
      case .latest(let feedIDs):
        guard feedIDs.isEmpty == false else { return .podcastsRoot }
        let placeholders = Array(repeating: "?", count: feedIDs.count).joined(separator: ",")
        let included =
          try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*) FROM rssFeed AS feed
              LEFT JOIN rssFeedSettings AS settings ON settings.feedId = feed.id
              WHERE feed.id IN (\(placeholders)) AND COALESCE(settings.includeInLatest, 1) = 1
              """,
            arguments: StatementArguments(feedIDs)) ?? 0
        return included > 0 ? .latest : .podcastsRoot
      }
    }
  }

  private func feedExists(_ db: Database, feedID: Int64) throws -> Bool {
    try Int64.fetchOne(db, sql: "SELECT id FROM rssFeed WHERE id = ?", arguments: [feedID]) != nil
  }
}
