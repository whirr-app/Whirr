import ABSApi
import Foundation
import Persistence

public enum RecentEpisodeRefreshCommitOutcome: Sendable, Equatable {
  case committed
  case notCommitted
}

/// The outcome of one recent-episode shelf refresh. Fetch failures are reported by library so the
/// owning `SyncEngine` can pace only those shelves on the next trigger; `commitOutcome` records
/// whether persistence actually landed independently of `writtenCount`.
public struct RecentEpisodeRefreshResult: Sendable, Equatable {
  public let writtenCount: Int
  public let failedLibraryIDs: [String]
  public let commitOutcome: RecentEpisodeRefreshCommitOutcome

  public init(
    writtenCount: Int, failedLibraryIDs: [String],
    commitOutcome: RecentEpisodeRefreshCommitOutcome = .notCommitted
  ) {
    self.writtenCount = writtenCount
    self.failedLibraryIDs = failedLibraryIDs
    self.commitOutcome = commitOutcome
  }
}

/// Keeps Home's "new this week" row current from the server's own newest-episodes shelf.
///
/// Recency comes from the shelf, not a locally expanded catalogue: one request per podcast
/// library, one commit for the payload, independent of any background crawl.
///
/// A show's complete episode list (and deletion inference) belongs to `PodcastRefreshCoordinator`'s
/// per-show expansion. This coordinator never soft-deletes: see `RecentEpisodeStore` for why a
/// partial payload must not be read as authoritative emptiness.
public struct RecentEpisodeRefreshCoordinator: Sendable {
  private let client: ABSClient
  private let store: RecentEpisodeStore
  private let limit: Int

  public init(database: AppDatabase, client: ABSClient, limit: Int = 50) {
    self.client = client
    store = RecentEpisodeStore(database: database)
    self.limit = limit
  }

  /// Returns the number of episodes written and the libraries whose shelf fetch failed. A failing
  /// library is skipped and the rest still land.
  ///
  /// Throws only when the commit itself failed or rolled back, so `SyncEngine`'s trigger call site
  /// can tell "a successful commit that wrote nothing new" (still worth reconciling from) from
  /// "the write never landed".
  @discardableResult
  public func refresh(
    account: TokenAccount,
    accountId: Int64,
    podcastLibraryIDs: [String]
  ) async throws -> RecentEpisodeRefreshResult {
    guard podcastLibraryIDs.isEmpty == false else {
      return RecentEpisodeRefreshResult(writtenCount: 0, failedLibraryIDs: [])
    }

    var upserts: [RecentEpisodeUpsert] = []
    var failedLibraryIDs: [String] = []
    for libraryID in podcastLibraryIDs {
      if Task.isCancelled { break }
      let shelf: [RecentEpisode]
      do {
        shelf = try await client.recentEpisodes(
          account: account, library: libraryID, limit: limit)
      } catch {
        failedLibraryIDs.append(libraryID)
        continue
      }
      upserts.append(contentsOf: shelf.map(Self.upsert))
    }

    guard upserts.isEmpty == false else {
      return RecentEpisodeRefreshResult(
        writtenCount: 0, failedLibraryIDs: failedLibraryIDs)
    }
    let writtenCount = try await store.apply(accountId: accountId, episodes: upserts)
    return RecentEpisodeRefreshResult(
      writtenCount: writtenCount, failedLibraryIDs: failedLibraryIDs, commitOutcome: .committed)
  }

  private static func upsert(_ recent: RecentEpisode) -> RecentEpisodeUpsert {
    let episode = recent.episode
    return RecentEpisodeUpsert(
      serverItemID: recent.libraryItemID,
      serverEpisodeID: episode.id,
      title: episode.title,
      subtitle: episode.subtitle,
      episodeDescription: episode.description,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      episodeType: episode.episodeType,
      mimeType: episode.mimeType,
      durationSeconds: episode.duration,
      sizeBytes: episode.size,
      publishedAt: episode.publishedAt,
      storedAudio: episode.audioFile.map {
        RecentEpisodeAudio(
          ino: $0.ino,
          expectedSize: $0.expectedSize,
          mimeType: $0.mimeType,
          durationSeconds: $0.duration)
      })
  }
}
