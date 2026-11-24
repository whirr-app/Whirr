import Persistence
import SyncEngine

/// The one implementation of every podcast episode action, for server and followed-feed episodes
/// alike. Only where progress is stored differs by source (the injected
/// `PodcastEpisodeProgressBackend`); playback safeguards, queue and saved identities, download
/// routing and failure copy live here once.
///
/// The queue is the universal `ListeningQueueStoring`, as `ItemActionsModel` and `PlaybackModel`
/// hold. Download stays with the injected download intent boundary, so this does not duplicate the
/// download coordinator.
@MainActor
public final class PlaybackPodcastEpisodeIntents: PodcastEpisodeIntents {
  private let playback: PlaybackModel
  private let queue: any ListeningQueueStoring
  private let downloadIntents: any DownloadIntents
  private let progress: any PodcastEpisodeProgressBackend
  private let savedShelf: any SavedShelfStoring

  public init(
    playback: PlaybackModel,
    queue: any ListeningQueueStoring,
    downloadIntents: any DownloadIntents,
    progress: any PodcastEpisodeProgressBackend,
    savedShelf: any SavedShelfStoring
  ) {
    self.playback = playback
    self.queue = queue
    self.downloadIntents = downloadIntents
    self.progress = progress
    self.savedShelf = savedShelf
  }

  /// `PlaybackModel.start` is non-throwing: it records why a start refused in
  /// `startFailureMessage` and leaves no active item behind. The shell owns the single alert for
  /// that shared state, so this intent does not create a second, screen-local failure surface.
  public func play(itemID: String, episodeID: String) async throws {
    try requireDecodable(itemID)
    await playback.start(itemID: itemID, episodeID: episodeID)
  }

  public func playNext(itemID: String, episodeID: String) async throws {
    try await queue.insertNext(identity: try listeningIdentity(itemID: itemID, episodeID: episodeID))
  }

  public func addToUpNext(itemID: String, episodeID: String) async throws {
    _ = try await queue.append(identity: try listeningIdentity(itemID: itemID, episodeID: episodeID))
  }

  /// Returns whether the shelf inserted a new identity or found this episode already saved.
  @discardableResult
  public func saveForLater(
    itemID: String, episodeID: String
  ) async throws -> SavedShelfSaveOutcome {
    try requireDecodable(itemID)
    do {
      return try await savedShelf.save(try savedIdentity(itemID: itemID, episodeID: episodeID))
    } catch {
      throw PodcastEpisodeIntentFailure(message: SavedForLaterCopy.saveFailed)
    }
  }

  public func removeFromSaved(itemID: String, episodeID: String) async throws {
    try requireDecodable(itemID)
    do {
      try await savedShelf.remove(try savedIdentity(itemID: itemID, episodeID: episodeID))
    } catch {
      throw PodcastEpisodeIntentFailure(message: SavedForLaterCopy.removeFailed)
    }
  }

  public func download(itemID: String, episodeID: String) async throws {
    try requireDecodable(itemID)
    try await downloadIntents.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
  }

  public func pauseDownload(itemID: String, episodeID: String) async throws {
    try requireDecodable(itemID)
    try await downloadIntents.pauseEpisodeDownload(itemID: itemID, episodeID: episodeID)
  }

  public func resumeDownload(itemID: String, episodeID: String) async throws {
    try requireDecodable(itemID)
    try await downloadIntents.resumeEpisodeDownload(itemID: itemID, episodeID: episodeID)
  }

  public func removeDownload(itemID: String, episodeID: String) async throws {
    try requireDecodable(itemID)
    try await downloadIntents.purgeEpisodeDownload(
      itemID: itemID, episodeID: episodeID, source: .podcastEpisodeRemoval)
  }

  /// Stops playback first, and only when this episode is the one playing. Finishing the episode
  /// under the playhead while it keeps running would write the position back over the completed
  /// one. A sibling episode of the same show is a different identity and is left alone. Once the
  /// write lands, the next continuation is prepared paused; playback never resumes.
  public func markAsFinished(itemID: String, episodeID: String, duration: Double?) async throws {
    try requireDecodable(itemID)
    let identity = try listeningIdentity(itemID: itemID, episodeID: episodeID)
    var generation: Int?
    if isActive(itemID: itemID, episodeID: episodeID) {
      await playback.stop()
      generation = playback.playbackGeneration
    }
    try await withCopy(PodcastCopy.actionFailed) {
      try await progress.markFinished(itemID: itemID, episodeID: episodeID, duration: duration)
    }
    if let generation {
      await playback.prepareContinuationPaused(
        after: identity, clearing: .everyRow, generation: generation)
    }
  }

  /// Mirrors the player's own reset: the durable intent lands first, then a live session for the
  /// same episode is moved back to the start so the screen and the playhead agree.
  public func resetProgress(itemID: String, episodeID: String) async throws {
    try requireDecodable(itemID)
    try await withCopy(PodcastCopy.actionFailed) {
      try await progress.resetProgress(itemID: itemID, episodeID: episodeID)
    }
    if isActive(itemID: itemID, episodeID: episodeID) {
      playback.seek(itemID: itemID, toGlobalOffset: 0)
    }
  }

  public func removeFromContinueListening(itemID: String, episodeID: String) async throws {
    try requireDecodable(itemID)
    try await withCopy(ContinueListeningCopy.removeFailed) {
      try await progress.hideFromContinueListening(itemID: itemID, episodeID: episodeID)
    }
  }

  /// No playback interlock here, unlike `markAsFinished`: a bulk mark from the show screen can
  /// include the episode under the playhead, and stopping playback because one of forty rows
  /// happened to be playing would be a surprise. The live session's own position writes are
  /// coalesced separately and a later tick simply wins.
  public func markAll(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    try requireDecodable(itemID)
    guard episodes.isEmpty == false else { return }
    try await withCopy(PodcastCopy.actionFailed) {
      try await progress.setFinished(itemID: itemID, episodes: episodes, isFinished: isFinished)
    }
  }

  private func isActive(itemID: String, episodeID: String) -> Bool {
    playback.activeItemID == itemID && playback.activeEpisodeID == episodeID
  }

  /// Every action is a direct tap on a row, so a malformed id fails visibly before anything is
  /// touched, whichever operation it reached.
  private func requireDecodable(_ itemID: String) throws {
    guard PodcastSourceIdentity(itemId: itemID) != nil else {
      throw PodcastEpisodeIntentFailure(message: PodcastCopy.actionFailed)
    }
  }

  private func listeningIdentity(itemID: String, episodeID: String) throws -> ListeningIdentity {
    try requireDecodable(itemID)
    guard let identity = ListeningIdentity.resolving(itemID: itemID, episodeID: episodeID)
    else { throw PodcastEpisodeIntentFailure(message: PodcastCopy.actionFailed) }
    return identity
  }

  private func savedIdentity(itemID: String, episodeID: String) throws -> SavedShelfIdentity {
    guard let identity = SavedShelfIdentity.resolving(itemID: itemID, episodeID: episodeID)
    else { throw PodcastEpisodeIntentFailure(message: PodcastCopy.actionFailed) }
    return identity
  }

  /// Each progress operation fails with one fixed message, whatever the backend threw.
  private func withCopy(_ message: String, _ write: () async throws -> Void) async throws {
    do {
      try await write()
    } catch {
      throw PodcastEpisodeIntentFailure(message: message)
    }
  }
}
