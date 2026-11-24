import Foundation
import GRDB

/// One episode from the recent-episodes shelf, addressed by server ids because the shelf spans a
/// whole library and the caller has no local row id for any of the shows it names.
public struct RecentEpisodeUpsert: Sendable, Equatable {
  public let serverItemID: String
  public let serverEpisodeID: String
  public let title: String?
  public let subtitle: String?
  public let episodeDescription: String?
  public let seasonNumber: String?
  public let episodeNumber: String?
  public let episodeType: String?
  public let mimeType: String?
  public let durationSeconds: Double?
  public let sizeBytes: Int?
  public let publishedAt: Date?
  public let storedAudio: RecentEpisodeAudio?

  public init(
    serverItemID: String,
    serverEpisodeID: String,
    title: String?,
    subtitle: String?,
    episodeDescription: String?,
    seasonNumber: String?,
    episodeNumber: String?,
    episodeType: String?,
    mimeType: String?,
    durationSeconds: Double?,
    sizeBytes: Int?,
    publishedAt: Date?,
    storedAudio: RecentEpisodeAudio?
  ) {
    self.serverItemID = serverItemID
    self.serverEpisodeID = serverEpisodeID
    self.title = title
    self.subtitle = subtitle
    self.episodeDescription = episodeDescription
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.episodeType = episodeType
    self.mimeType = mimeType
    self.durationSeconds = durationSeconds
    self.sizeBytes = sizeBytes
    self.publishedAt = publishedAt
    self.storedAudio = storedAudio
  }
}

public struct RecentEpisodeAudio: Sendable, Equatable {
  public let ino: String
  public let expectedSize: Int
  public let mimeType: String
  public let durationSeconds: Double

  public init(ino: String, expectedSize: Int, mimeType: String, durationSeconds: Double) {
    self.ino = ino
    self.expectedSize = expectedSize
    self.mimeType = mimeType
    self.durationSeconds = durationSeconds
  }
}

/// Writes the recent-episodes shelf into the episode table.
///
/// Not `PodcastRefreshStore.applyPodcastRefresh`, which soft-deletes a show's unmentioned episodes
/// on a complete response. The shelf is only the newest few across a library, so it upserts what
/// it carries and touches nothing else.
public struct RecentEpisodeStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Applies the whole payload in one transaction, so Home's observations re-run once however many
  /// shows the shelf spans. Returns the number of episodes written. An episode naming a show
  /// outside this account's live included catalogue is skipped, since there is no discovery
  /// surface it may update.
  @discardableResult
  public func apply(accountId: Int64, episodes: [RecentEpisodeUpsert]) async throws -> Int {
    guard episodes.isEmpty == false else { return 0 }
    return try await database.writeAsync { db in
      var localItemIDByServerID: [String: Int64] = [:]
      var generationByLocalItemID: [Int64: Int] = [:]
      var applied = 0

      for episode in episodes {
        let localItemID: Int64?
        if let cached = localItemIDByServerID[episode.serverItemID] {
          localItemID = cached
        } else {
          localItemID = try Int64.fetchOne(
            db,
            sql: """
              SELECT item.id FROM item
              JOIN library ON library.id = item.libraryId AND library.accountId = item.accountId
              WHERE item.accountId = ? AND item.serverItemId = ? AND item.mediaKind = 'podcast'
                AND \(ItemVisibilityPredicate.sql)
              """,
            arguments: [accountId, episode.serverItemID])
          if let localItemID { localItemIDByServerID[episode.serverItemID] = localItemID }
        }
        guard let localItemID else { continue }

        // Join the show's existing generation rather than opening a new one. A later complete
        // refresh takes `MAX(lastSeenGeneration) + 1` and sweeps everything it does not re-see.
        // Raising the ceiling here would let that generation collide with rows it never visited,
        // and real server-side deletions would stop being noticed.
        let generation: Int
        if let cached = generationByLocalItemID[localItemID] {
          generation = cached
        } else {
          generation =
            try Int.fetchOne(
              db,
              sql: "SELECT MAX(lastSeenGeneration) FROM podcastEpisode WHERE itemId = ?",
              arguments: [localItemID]) ?? 0
          generationByLocalItemID[localItemID] = generation
        }

        let existing =
          try PodcastEpisodeRecord
          .filter(Column("itemId") == localItemID)
          .filter(Column("serverEpisodeId") == episode.serverEpisodeID)
          .fetchOne(db)

        var record = PodcastEpisodeRecord(
          id: existing?.id,
          accountId: accountId,
          itemId: localItemID,
          serverEpisodeId: episode.serverEpisodeID,
          title: episode.title ?? "",
          subtitle: episode.subtitle,
          episodeDescription: episode.episodeDescription,
          seasonNumber: episode.seasonNumber,
          episodeNumber: episode.episodeNumber,
          episodeType: episode.episodeType,
          mimeType: episode.mimeType,
          durationSeconds: episode.durationSeconds,
          sizeBytes: episode.sizeBytes,
          publishedAt: episode.publishedAt,
          storedAudioIno: episode.storedAudio?.ino,
          storedAudioExpectedSize: episode.storedAudio?.expectedSize,
          storedAudioMimeType: episode.storedAudio?.mimeType,
          storedAudioDurationSeconds: episode.storedAudio?.durationSeconds,
          // An episode the shelf is currently advertising exists on the server by definition, so a
          // row previously tombstoned by a stale sweep comes back live.
          lastSeenGeneration: existing?.lastSeenGeneration ?? generation,
          softDeleted: false)
        try record.save(db)
        applied += 1
      }

      return applied
    }
  }
}
