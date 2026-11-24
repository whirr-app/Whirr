import ABSApi
import Observation
import Persistence

/// The shell-lifetime answer to which artwork source belongs to a followed show. A playback
/// bookmark carries no RSS artwork declaration, so `CoverImageView` can't infer it; held beside
/// the shell, it gives the player the real source on the first frame instead of the generated
/// placeholder key. On cold launch until `observeShows()` emits, a source-less item stays unknown
/// and callers keep their fallback.
@MainActor @Observable
final class FollowedShowArtworkSources {
  private(set) var sourcesByItemID: [String: ArtworkSource] = [:]
  private let onSourceChanged: @MainActor (String) -> Void
  @ObservationIgnored private var observationTask: Task<Void, Never>?

  init(
    reading: any NativePodcastShowsReading,
    onSourceChanged: @escaping @MainActor (String) -> Void = { _ in }
  ) {
    self.onSourceChanged = onSourceChanged
    observationTask = Task { [weak self, reading] in
      for await snapshot in reading.observeShows() {
        guard Task.isCancelled == false else { break }
        self?.apply(snapshot)
      }
    }
  }

  /// Applies the same projection rule used by every other App artwork caller. Server-owned
  /// items, malformed RSS identities, and shows without both validated artwork URLs are omitted.
  func apply(_ snapshot: NativePodcastShowsSnapshot) {
    let nextSources = Dictionary(
      uniqueKeysWithValues: snapshot.shows.compactMap { summary in
        summary.providerArtworkSource.map { (summary.serverItemId, $0) }
      })
    let changedIDs = Set(sourcesByItemID.keys).union(nextSources.keys).filter {
      sourcesByItemID[$0] != nextSources[$0]
    }
    sourcesByItemID = nextSources
    for itemID in changedIDs {
      onSourceChanged(itemID)
    }
  }

  /// Returns nil both for a server item and for an RSS item not present in the latest observed
  /// snapshot. Callers may use their loaded projection as a later fallback in the latter case.
  func source(for itemID: String) -> ArtworkSource? {
    sourcesByItemID[itemID]
  }

  deinit {
    observationTask?.cancel()
  }
}
