import Foundation
import GRDB

/// The image an RSS episode itself declares, observed so a refresh that adds or changes it
/// reaches a surface already showing the episode.
public protocol RSSEpisodeArtworkReading: Sendable {
  /// The stored artwork URL for the episode now, then after every change to it. `nil` when the
  /// episode is unknown or declares no image of its own.
  func observeEpisodeArtworkURL(feedId: Int64, identityKey: String) -> AsyncStream<URL?>
}

/// Answers `nil` for every episode: compositions with no database of RSS episodes.
public struct NoOpRSSEpisodeArtworkReading: RSSEpisodeArtworkReading, Sendable {
  public init() {}

  public func observeEpisodeArtworkURL(feedId: Int64, identityKey: String) -> AsyncStream<URL?> {
    AsyncStream { continuation in
      continuation.yield(nil)
      continuation.finish()
    }
  }
}

public struct DefaultRSSEpisodeArtworkReading: RSSEpisodeArtworkReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) { self.database = database }

  public func observeEpisodeArtworkURL(feedId: Int64, identityKey: String) -> AsyncStream<URL?> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db -> URL? in
        let value = try String.fetchOne(
          db,
          sql: "SELECT artworkURL FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
          arguments: [feedId, identityKey])
        return value.flatMap(URL.init(string:))
      }.removeDuplicates())
  }
}
