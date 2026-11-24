import Foundation
import GRDB
import Persistence

extension PodcastCloudLocalCatalogue {
  /// One episode's identity material as the cloud pipeline reads it.
  ///
  /// Publication, projection and the Saved-intent resolver all need the same episode row joined to
  /// its feed. Reading it through one query keeps their column list, duration expression and join
  /// identical, so a new identity column lands in every caller at once.
  struct EpisodeIdentity: Equatable {
    let feedURL: String
    let identityKey: String
    let alternateIdentityKey: String?
    let guid: String?
    let enclosureURL: String?
    let title: String?
    let publishedAt: Date?
    let duration: Double?

    /// The full wire identity. Callers that publish a narrower value build its fields themselves
    /// rather than widening a record by accident.
    var fields: PodcastCloudEpisodeIdentityFields {
      PodcastCloudEpisodeIdentityFields(
        identityKey: identityKey, alternateIdentityKey: alternateIdentityKey, guid: guid,
        enclosureURL: enclosureURL, title: title, publishedAt: publishedAt, duration: duration)
    }
  }

  static func episodeIdentity(episodeId: Int64, in db: Database) throws -> EpisodeIdentity? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT episode.identityKey AS identityKey, episode.alternateIdentityKey AS alternateIdentityKey,
                 episode.guid AS guid, episode.enclosureURL AS enclosureURL, episode.title AS title,
                 episode.publishedAt AS publishedAt,
                 COALESCE(episode.durationSeconds, episode.measuredDurationSeconds) AS duration,
                 feed.feedURL AS feedURL
          FROM rssEpisode AS episode JOIN rssFeed AS feed ON feed.id = episode.feedId
          WHERE episode.id = ?
          """, arguments: [episodeId])
    else { return nil }
    let identityKey: String = row["identityKey"]
    return EpisodeIdentity(
      feedURL: row["feedURL"], identityKey: identityKey,
      alternateIdentityKey: row["alternateIdentityKey"], guid: row["guid"],
      enclosureURL: row["enclosureURL"], title: row["title"], publishedAt: row["publishedAt"],
      duration: row["duration"])
  }
}
