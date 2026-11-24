import Observation
import Persistence

/// One screen's shared item-playback-state projection.
///
/// The read side of "Mark as Finished": the coarse playback state the server (or an unsynced
/// local intent) records, which browse rows and item detail consult synchronously.
///
/// Modelled on `DownloadStatusStore` and as coarse: it carries no position, so a playback tick
/// (writing `mediaProgress` several times a minute) re-runs the query but invalidates no row. Item
/// detail consumes the finished facet; Library consumes both states.
@MainActor
@Observable
public final class FinishedStatusStore {
  private var playbackStatuses: [String: ItemPlaybackStatus] = [:]
  private var episodePlaybackStatuses: [ListeningIdentity: ItemPlaybackStatus] = [:]

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var episodeTask: Task<Void, Never>?

  public init(library: any LibraryReading) {
    // Subscribed synchronously in `init`, not inside the `Task` below, so the first emission
    // cannot be missed.
    let stream = library.observeItemPlaybackStatuses()
    let episodeStream = library.observeEpisodePlaybackStatuses()
    task = Task { [weak self] in
      for await statuses in stream {
        guard let self else { return }
        // Assigned wholesale, never merged: an item whose progress was reset drops out rather
        // than arriving as an explicit "not started" value.
        self.playbackStatuses = statuses
      }
    }
    episodeTask = Task { [weak self] in
      for await statuses in episodeStream {
        guard let self else { return }
        self.episodePlaybackStatuses = statuses
      }
    }
  }

  deinit {
    task?.cancel()
    episodeTask?.cancel()
  }

  /// Whether this item's own progress is finished. An item absent from the projection has no
  /// finished progress row.
  public func isFinished(_ itemID: String) -> Bool {
    playbackStatuses[itemID] == .finished
  }

  public func playbackStatus(_ itemID: String) -> ItemPlaybackStatus? {
    playbackStatuses[itemID]
  }

  /// The status of the row a `(itemID, episodeID?)` pair names. With an episode id this is the
  /// episode's own progress and never its show's: a finished show has untouched episodes, and a
  /// finished episode does not finish its show. Surfaces that list both kinds (Search) read
  /// through here so the two cannot be confused.
  public func playbackStatus(itemID: String, episodeID: String?) -> ItemPlaybackStatus? {
    guard let episodeID else { return playbackStatuses[itemID] }
    guard let identity = ListeningIdentity.podcastEpisode(itemID: itemID, episodeID: episodeID)
    else { return nil }
    return episodePlaybackStatuses[identity]
  }
}
