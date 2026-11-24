import Persistence
import SyncEngine

/// Server episodes write through the account-scoped progress intents and their outbox. Delete
/// After Playing is applied inside `ItemProgressCoordinator`, where the same rule also covers
/// books and player-driven finishes, so this is a direct pass-through.
public struct ABSEpisodeProgressBackend: PodcastEpisodeProgressBackend {
  private let progressIntents: any ItemProgressIntents

  public init(progressIntents: any ItemProgressIntents) {
    self.progressIntents = progressIntents
  }

  public func markFinished(itemID: String, episodeID: String, duration: Double?) async throws {
    try await progressIntents.markAsFinished(
      itemID: itemID, episodeID: episodeID, duration: duration)
  }

  public func resetProgress(itemID: String, episodeID: String) async throws {
    try await progressIntents.resetProgress(itemID: itemID, episodeID: episodeID)
  }

  public func hideFromContinueListening(itemID: String, episodeID: String) async throws {
    try await progressIntents.setContinueListeningVisibility(
      itemID: itemID, episodeID: episodeID, isHidden: true)
  }

  public func setFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    try await progressIntents.setEpisodesFinished(
      itemID: itemID, episodes: episodes, isFinished: isFinished)
  }
}
