import Persistence

/// Picks the progress backend by the typed source encoded in the serialized item id.
///
/// Unlike the read-side router, an undecodable id is an action failure rather than a silent
/// no-op: episode actions are direct user taps, so swallowing a malformed id would hide a bug.
public struct RoutingPodcastEpisodeProgressBackend: PodcastEpisodeProgressBackend {
  private let abs: any PodcastEpisodeProgressBackend
  private let rss: any PodcastEpisodeProgressBackend

  public init(abs: any PodcastEpisodeProgressBackend, rss: any PodcastEpisodeProgressBackend) {
    self.abs = abs
    self.rss = rss
  }

  public func markFinished(itemID: String, episodeID: String, duration: Double?) async throws {
    try await backend(for: itemID).markFinished(
      itemID: itemID, episodeID: episodeID, duration: duration)
  }

  public func resetProgress(itemID: String, episodeID: String) async throws {
    try await backend(for: itemID).resetProgress(itemID: itemID, episodeID: episodeID)
  }

  public func hideFromContinueListening(itemID: String, episodeID: String) async throws {
    try await backend(for: itemID).hideFromContinueListening(
      itemID: itemID, episodeID: episodeID)
  }

  public func setFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    try await backend(for: itemID).setFinished(
      itemID: itemID, episodes: episodes, isFinished: isFinished)
  }

  private func backend(for itemID: String) throws -> any PodcastEpisodeProgressBackend {
    guard let identity = PodcastSourceIdentity(itemId: itemID) else {
      throw PodcastEpisodeIntentFailure(message: PodcastCopy.actionFailed)
    }
    return switch identity.source {
    case .abs: abs
    case .rss: rss
    }
  }
}
