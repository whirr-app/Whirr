import Foundation
import Persistence
import SyncEngine

/// Followed-feed episodes keep their progress in device-owned state, never the ABS outbox.
///
/// A finish is the same transition for either source, so this takes the same "Delete After
/// Playing" preference and cleanup action as `ItemProgressCoordinator` and applies them the same
/// way: only after the finished state has durably landed, once per finished identity.
public struct RSSEpisodeProgressBackend: PodcastEpisodeProgressBackend {
  private let episodeStore: RSSEpisodeStore
  private let stateStore: RSSEpisodeStateStore
  private let downloadPreferences: any DownloadPreferences
  private let requestFinishedDownloadDeletion: @Sendable (String, String?) async -> Void

  public init(
    episodeStore: RSSEpisodeStore,
    stateStore: RSSEpisodeStateStore,
    downloadPreferences: any DownloadPreferences,
    requestFinishedDownloadDeletion: @escaping @Sendable (String, String?) async -> Void
  ) {
    self.episodeStore = episodeStore
    self.stateStore = stateStore
    self.downloadPreferences = downloadPreferences
    self.requestFinishedDownloadDeletion = requestFinishedDownloadDeletion
  }

  public func markFinished(itemID: String, episodeID: String, duration: Double?) async throws {
    let rssEpisodeID = try await rssEpisodeID(itemID: itemID, episodeID: episodeID)
    // `duration` is the ABS path's server-facing end position. Device-owned state keeps `finished`
    // as its own column, so the stored position is not snapped to a duration the feed may only
    // have declared approximately. Saved for Later resolves on the finished flag
    // (`NativeSavedIntentResolving`, inside the store's transaction), so the untouched position
    // does not leave the episode on that shelf.
    _ = duration
    _ = try await stateStore.setFinished(episodeId: rssEpisodeID, finished: true, now: Date())
    // Cleanup only after the durable finish: a failed write above throws before this line, so a
    // download is never removed for a finish that did not land.
    guard downloadPreferences.deleteWhenFinished else { return }
    await requestFinishedDownloadDeletion(itemID, episodeID)
  }

  public func resetProgress(itemID: String, episodeID: String) async throws {
    let rssEpisodeID = try await rssEpisodeID(itemID: itemID, episodeID: episodeID)
    _ = try await stateStore.resetProgress(episodeId: rssEpisodeID, now: Date())
  }

  public func hideFromContinueListening(itemID: String, episodeID: String) async throws {
    let rssEpisodeID = try await rssEpisodeID(itemID: itemID, episodeID: episodeID)
    _ = try await stateStore.setHiddenFromContinueListening(
      episodeId: rssEpisodeID, isHidden: true, now: Date())
  }

  public func setFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    var rssEpisodeIDs: [Int64] = []
    for episode in episodes {
      rssEpisodeIDs.append(try await rssEpisodeID(itemID: itemID, episodeID: episode.episodeID))
    }
    // One transaction for the whole set, so a failure part-way cannot leave the show half-marked
    // while the caller is told the action failed outright.
    try await stateStore.setFinished(
      episodeIds: rssEpisodeIDs, finished: isFinished, now: Date())
    guard isFinished, downloadPreferences.deleteWhenFinished else { return }
    for episode in episodes {
      await requestFinishedDownloadDeletion(itemID, episode.episodeID)
    }
  }

  private func rssEpisodeID(itemID: String, episodeID: String) async throws -> Int64 {
    guard
      let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId,
      let row = try await episodeStore.fetchEpisode(feedId: feedID, identityKey: episodeID),
      let id = row.id
    else { throw PodcastEpisodeIntentFailure(message: PodcastCopy.actionFailed) }
    return id
  }
}
