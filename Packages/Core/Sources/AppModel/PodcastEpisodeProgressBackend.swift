import Persistence

/// The four episode operations whose storage differs by source. Implementations persist and
/// return; ordering against live playback, and the copy a failure shows, are the caller's job
/// (`PlaybackPodcastEpisodeIntents`).
public protocol PodcastEpisodeProgressBackend: Sendable {
  func markFinished(itemID: String, episodeID: String, duration: Double?) async throws
  func resetProgress(itemID: String, episodeID: String) async throws
  func hideFromContinueListening(itemID: String, episodeID: String) async throws
  /// The show-level bulk write: every supplied episode in one transaction.
  func setFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws
}
