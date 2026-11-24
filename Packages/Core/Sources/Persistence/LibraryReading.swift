import Foundation

/// Read side of the local store. Screens observe projections of this, never the network
/// (ARCHITECTURE.md §2). GRDB `ValueObservation` is bridged to `AsyncStream`, so AppModel
/// consumes a plain `AsyncSequence` and never sees a GRDB type (ARCHITECTURE.md §1).
public protocol LibraryReading: Sendable {
  var itemCount: Int { get }

  /// The browse list for `libraryId` (the server-reported id), sorted for display, re-emitted on
  /// insert/update/soft-delete; soft-deleted rows never appear. Runs off the main actor (GRDB's
  /// default observation scheduler); AppModel hops to main only to assign into `@Observable` state.
  func observeBrowseList(libraryId: String) -> AsyncStream<[ItemSummary]>

  /// The browse list across every synced library: the Library tab shows one merged list, divided
  /// only by `category` (nil for no constraint). Same sorting, soft-delete and off-main-actor
  /// contract as the library-scoped overload above.
  func observeBrowseList(category: ItemMediaCategory?) -> AsyncStream<[ItemSummary]>

  /// The same merged cross-library list, narrowed by the composite `BrowseFilters`: media
  /// category plus the download and playback dimensions the category overload cannot express.
  /// Same sorting, soft-delete and off-main-actor contract.
  ///
  /// Yields a `LibraryBrowseSnapshot`, not a bare array, so a screen with a persisted filter can
  /// tell "your filter matched nothing" from "your library is empty"; both values come from one
  /// tracked read.
  ///
  /// The tracked region includes `download` and `mediaProgress` whenever those dimensions are
  /// active: a completing transfer, a finished-state change, or a position crossing zero (Unplayed
  /// to In Progress) is a membership change and must re-emit. Writes leaving the snapshot equal
  /// (byte checkpoints, later playback ticks) are deduplicated.
  func observeBrowseList(filters: BrowseFilters) -> AsyncStream<LibraryBrowseSnapshot>

  /// This library's sync-run status, re-emitted whenever a run for this library starts,
  /// finishes, or completes. Lets `LibraryBrowseModel` tell "still syncing" and "stale-offline"
  /// from a plain loaded list.
  func observeSyncStatus(libraryId: String) -> AsyncStream<LibrarySyncStatus>

  /// Every library's sync-run status folded into one for the cross-library list: running if any
  /// is, last-run-incomplete if any library's latest run was, and `lastCompletedAt` from the
  /// oldest completion (a merged list is only as fresh as its stalest library), nil if any has
  /// none.
  func observeAggregateSyncStatus() -> AsyncStream<LibrarySyncStatus>

  /// One item's retained projection (nil once absent or soft-deleted), re-emitted on change.
  /// `itemId` is the server item id, as `NavigationModel.Route.itemDetail` carries. Does not apply
  /// library inclusion: player, download and Up Next routes may still open an excluded library's
  /// retained item. The synchronous sibling stays for direct cache readers; presentation models
  /// carry an optional display seed and use this observation as their sole loader.
  func currentItemDetail(itemId: String) -> ItemSummary?
  func observeItemDetail(itemId: String) -> AsyncStream<ItemSummary?>

  /// The stored audio position for one listening identity (`episodeId` nil for the item row) and
  /// when it last changed: the local write's time when this device wrote it last, else the
  /// server's `lastUpdate` for the pulled value. Like `currentItemDetail`, ignores library
  /// inclusion.
  func currentAudioProgress(itemId: String, episodeId: String?) -> StoredAudioProgress?

  /// Resolves ordered server item ids (as `SyncCoordinating.search` returns them) to live
  /// projections, preserving order and dropping ids with no non-soft-deleted row. Re-emitted as
  /// rows change, so a sync run's deletion inference reaches rendered search results.
  func observeItems(ids: [String]) -> AsyncStream<[ItemSummary]>

  /// Every server item id whose item-level progress is in progress or finished, account-scoped
  /// and cross-library; drives Library's half-filled circle and finished checkmark. Coarse, like
  /// `DownloadReading.observeItemDownloadPresence`: no position, so a playback tick re-runs the
  /// query but yields nothing new, and one subscription replaces per-row observation. Audio
  /// position and ebook percentage both count. Episode-scoped progress never appears here.
  func observeItemPlaybackStatuses() -> AsyncStream<[String: ItemPlaybackStatus]>

  /// The episode-scoped twin of `observeItemPlaybackStatuses`, keyed by listening identity so an
  /// episode is never answered with its show's row (Search once offered Reset on every episode of
  /// a finished show). Equally coarse, one screen-wide subscription. Audio position and finished
  /// count; an episode has no ebook edition.
  func observeEpisodePlaybackStatuses() -> AsyncStream<[ListeningIdentity: ItemPlaybackStatus]>

  /// The account-scoped set of identities whose progress row is explicitly hidden from Continue
  /// Listening. A membership set rather than a per-item flag because only hidden rows appear,
  /// which is near-empty in ordinary use. Episode-scoped hiding never becomes its show's identity.
  func observeContinueListeningHidden() -> AsyncStream<Set<ListeningIdentity>>

  /// Detailed item-level positions for one visible set of rows. Unlike the coarse status
  /// projection above, this republishes as positions change, so scope it to the item ids being
  /// drawn. Episode progress stays separate from its parent show.
  func observeItemPlaybackProgress(itemIDs: Set<String>)
    -> AsyncStream<[String: ItemPlaybackProgress]>
}

/// Existing lightweight test and harness readers can remain observation-only. Production and the
/// shared fake override this to provide the cached first frame.
extension LibraryReading {
  public func currentItemDetail(itemId: String) -> ItemSummary? { nil }
  public func currentAudioProgress(itemId: String, episodeId: String?) -> StoredAudioProgress? { nil }

  public func observeContinueListeningHidden() -> AsyncStream<Set<ListeningIdentity>> {
    AsyncStream { continuation in
      continuation.yield([])
      continuation.finish()
    }
  }

  public func observeEpisodePlaybackStatuses() -> AsyncStream<[ListeningIdentity: ItemPlaybackStatus]> {
    AsyncStream { continuation in
      continuation.yield([:])
      continuation.finish()
    }
  }

  public func observeItemPlaybackProgress(itemIDs: Set<String>)
    -> AsyncStream<[String: ItemPlaybackProgress]>
  {
    AsyncStream { continuation in
      continuation.yield([:])
      continuation.finish()
    }
  }
}

public enum ItemPlaybackStatus: Sendable, Equatable {
  case inProgress
  case finished
}

/// One listening identity's stored audio position and the time it last changed.
public struct StoredAudioProgress: Sendable, Equatable {
  public let position: Double
  public let isFinished: Bool
  public let changedAt: Date?

  public init(position: Double, isFinished: Bool, changedAt: Date?) {
    self.position = position
    self.isFinished = isFinished
    self.changedAt = changedAt
  }
}

/// The raw persisted position for one item-level progress row. AppModel combines it with the
/// row's media category and duration to derive a presentation fraction; Persistence does not
/// decide whether seconds or ebook percentage is the relevant signal.
public struct ItemPlaybackProgress: Sendable, Equatable {
  public let currentTime: Double
  public let ebookProgress: Double?
  public let isFinished: Bool

  public init(currentTime: Double, ebookProgress: Double? = nil, isFinished: Bool) {
    self.currentTime = currentTime
    self.ebookProgress = ebookProgress
    self.isFinished = isFinished
  }
}

/// One emission of the filtered browse list: the rows that passed the filter, plus how many
/// non-soft-deleted rows exist ignoring it. `unfilteredItemCount` travels in the same value
/// because `LibraryReading.itemCount` is not observation-scoped and counts soft-deleted rows, so
/// it cannot answer "is this list empty because of my filter?".
public struct LibraryBrowseSnapshot: Sendable, Equatable {
  public let items: [ItemSummary]
  public let unfilteredItemCount: Int

  public init(items: [ItemSummary], unfilteredItemCount: Int) {
    self.items = items
    self.unfilteredItemCount = unfilteredItemCount
  }

  /// True when the library holds rows the filter is hiding: an over-narrow filter, not an empty
  /// library.
  public var hasUnfilteredItems: Bool { unfilteredItemCount > 0 }
}
