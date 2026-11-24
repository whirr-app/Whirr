import Observation
import Persistence

/// One screen's shared download-state projection.
///
/// A single subscription serves the whole screen. Rows read it synchronously and hold no per-row
/// model (which would open a GRDB `ValueObservation` from throwaway `View.init` calls).
///
/// Coarse: `ItemDownloadPresence` carries no progress fraction, so a download in flight does not
/// invalidate every row. Item detail needs per-state copy and keeps its own `ItemDownloadModel`
/// (`observeItemDownloadStatus`).
@MainActor
@Observable
public final class DownloadStatusStore {
  private var presenceByItemID: [String: ItemDownloadPresence] = [:]
  private var presenceByEpisode: [EpisodeDownloadKey: ItemDownloadPresence] = [:]
  /// Show IDs with at least one episode download presence row. This is stored separately from the
  /// raw episode map so value-only presence changes do not republish this filter membership.
  public private(set) var downloadedPodcastItemIDs: Set<String> = []

  /// True once the item projection has emitted at least once, so an absent key genuinely means
  /// "no downloads" rather than "not read yet". Only a seeding caller needs this; every row
  /// reader already renders the empty map as no-badge and refreshes when it fills.
  public private(set) var hasResolvedPresence = false

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var episodeTask: Task<Void, Never>?

  public init(downloadReading: any DownloadReading) {
    // Subscribed synchronously in `init`, not inside the `Task` below, so the first emission
    // cannot be missed. One store per screen, so real work in `init` is not a scroll-path cost.
    let stream = downloadReading.observeItemDownloadPresence()
    task = Task { [weak self] in
      for await presence in stream {
        guard let self else { return }
        // Assigned wholesale, never merged: an item whose downloads were removed drops out of
        // the map rather than arriving as an explicit `.none`.
        self.presenceByItemID = presence
        if self.hasResolvedPresence == false { self.hasResolvedPresence = true }
      }
    }

    // A second observation, not a second store: the episode projection is a disjoint set of rows
    // (`DownloadStore.itemPresence` excludes what `episodePresence` selects), and the same
    // shell-scoped instance serves both. The player's overflow menu acts on an episode while
    // every list row acts on an item.
    let episodeStream = downloadReading.observeEpisodeDownloadPresence()
    episodeTask = Task { [weak self] in
      for await presence in episodeStream {
        guard let self else { return }
        self.presenceByEpisode = presence
        let downloadedPodcastItemIDs = Set(presence.keys.map(\.itemID))
        if self.downloadedPodcastItemIDs != downloadedPodcastItemIDs {
          self.downloadedPodcastItemIDs = downloadedPodcastItemIDs
        }
      }
    }
  }

  deinit {
    task?.cancel()
    episodeTask?.cancel()
  }

  /// This item's coarse download summary, or with `episodeID` that one episode's. An identity
  /// absent from its projection has no download rows.
  public func presence(for itemID: String, episodeID: String? = nil) -> ItemDownloadPresence {
    guard let episodeID else { return presenceByItemID[itemID] ?? .none }
    return presenceByEpisode[EpisodeDownloadKey(itemID: itemID, episodeID: episodeID)] ?? .none
  }

  /// The "downloaded"/"available offline" badge condition. True only once every live row across
  /// every requested medium has verified locally and at least one live row exists, matching
  /// `ItemDownloadModel.isDownloaded`.
  public func isDownloaded(_ itemID: String) -> Bool {
    presence(for: itemID) == .completed
  }

  /// This item's coarse presence widened into the detailed status item detail renders from. `nil`
  /// until the projection has resolved, since a cold launch cannot tell an undownloaded item from
  /// an unread one.
  ///
  /// Lets the download cluster render on its first frame instead of waiting on
  /// `currentItemDownloadStatusAsync`, which queues behind the sync engine and download writer.
  /// Provisional: `ItemDownloadModel`'s observation replaces it with the exact state.
  public func provisionalStatus(for itemID: String) -> ItemDownloadStatus? {
    guard hasResolvedPresence else { return nil }
    switch presence(for: itemID) {
    case .none: return .notDownloaded
    case .completed: return .completed
    case .deleting: return .deleting
    // `.partial` collapses queued/waiting/in-flight/paused/interrupted/failed. `.queued` is the
    // member that promises least: it offers the same remove affordance they all share and draws
    // no progress arc, so nothing on screen has to be walked back a moment later.
    case .partial: return .queued
    }
  }

  /// The download affordance a menu should offer for this item, or for one of its episodes.
  public func downloadAction(for itemID: String, episodeID: String? = nil)
    -> ItemContextMenuDownloadAction
  {
    switch presence(for: itemID, episodeID: episodeID) {
    case .none: return .download
    case .deleting: return .unavailable
    case .partial, .completed: return .remove
    }
  }
}
