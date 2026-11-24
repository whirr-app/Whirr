import CoreSupport
import Foundation
import Observation
import Persistence
import SyncEngine

/// Library browse. Populates entirely from `LibraryReading`'s observed projections (construction
/// never calls the network) and forwards pull-to-refresh to `SyncCoordinating.refresh()`.
/// `libraryId` is the server-reported library id, the same identity `LibraryReading`'s methods
/// take.
@MainActor
@Observable
public final class LibraryBrowseModel {
  public enum State: Sendable, Equatable {
    /// Neither the item list nor the sync-status observation has emitted its first value yet.
    case loading
    /// No items, and nothing is syncing or has ever failed to sync.
    case empty
    /// The common case: a non-empty, fully-settled list.
    case loaded([ItemSummary])
    /// A sync run for this library is in progress. Carries the items so far.
    case partiallySynced([ItemSummary])
    /// The last attempt did not complete, no items are cached to fall back on, and nothing is
    /// currently running.
    case error
    /// The last attempt did not complete, cached items are stale (older than `staleAfter`), and
    /// nothing is currently running. Show the cache with an offline note.
    case staleOffline([ItemSummary])
    /// The library holds rows, but the active filter matches none of them. Distinct from `.empty`
    /// because the filter persists across launches: a reader who quit while filtered to Downloaded
    /// must not be told their library is empty.
    case filteredEmpty
  }

  public private(set) var state: State = .loading {
    didSet { stateRevision &+= 1 }
  }

  /// The composite filter, settable directly. Only an actual change re-subscribes, so re-picking
  /// the engaged media kind or re-toggling Downloaded to its current value is a no-op.
  ///
  /// Writing this persists before re-subscribing, so the value that survives a crash is the one the
  /// screen is about to show, never the one it just left.
  public var filters: BrowseFilters {
    didSet {
      guard filters != oldValue else { return }
      BrowseFilterStorage.save(filters, for: .library, to: defaults)
      subscribe(filters: filters)
    }
  }

  /// A compatibility projection for callers that need the older single-kind vocabulary. The
  /// Library filter itself is held in `filters.categories`, which may contain multiple kinds.
  public var mediaFilter: MediaFilter { MediaFilter(browseCategories: filters.categories) }

  private let library: any LibraryReading
  private let sync: any SyncCoordinating
  private let clock: any SyncClock
  private let staleAfter: TimeInterval
  private let defaults: any BrowseFilterDefaults

  private var latestSnapshot: LibraryBrowseSnapshot?
  private var latestStatus: LibrarySyncStatus?

  /// Scroll-phase callbacks write this gate frequently; it must not participate in view
  /// invalidation because the Library root never reads it from its body.
  @ObservationIgnored private var presentationDeferred = false
  @ObservationIgnored private var presentationUpdatePending = false
  @ObservationIgnored private var generationHasPublished = false

  /// Shared with `HomeModel`: the gate keeps a filter generation's list and status observations
  /// synchronized, rejects late values from superseded filters, and lets the current rendered
  /// state stay in place until both new sources are ready.
  @ObservationIgnored private var filterObservations = FilterObservationCoordinator()

  @ObservationIgnored private var stateRevision = 0
  @ObservationIgnored private var titleSearchKeys = LibraryQuickFilter.SearchKeyCache()
  @ObservationIgnored private var quickFilterMemo: QuickFilterMemo?
  private struct QuickFilterMemo {
    let stateRevision: Int
    let fragments: [String]
    let result: [ItemSummary]
  }

  public init(
    library: any LibraryReading,
    sync: any SyncCoordinating,
    defaults: any BrowseFilterDefaults = UserDefaults.standard,
    clock: any SyncClock = SystemSyncClock(),
    staleAfter: TimeInterval = AppModelStaleness.defaultStaleAfter
  ) {
    self.library = library
    self.sync = sync
    self.clock = clock
    self.staleAfter = staleAfter
    self.defaults = defaults

    // The persisted filter is the starting one. Multiple media kinds are valid here: the Library
    // filter combines them with each other and with Downloaded/playback.
    let stored = BrowseFilterStorage.load(.library, from: defaults)
    filters = stored

    // Explicit first subscribe: `filters`'s `didSet` does not fire for a stored property's own
    // initializer.
    subscribe(filters: stored)
  }

  // MARK: - Quick filter

  /// The rendered rows narrowed by the root's quick filter, or none when the state carries no rows.
  /// Read by the root's selection, the compact Titles list and the grid on every pass, so the
  /// answer is kept until rows or query change, and the key cache rebuilds only rows whose title or
  /// author changed.
  public func quickFilteredItems(query: String) -> [ItemSummary] {
    // Read through the observed accessor even on a cache hit, so a caller stays subscribed to the
    // rows the answer was derived from.
    let state = self.state
    let fragments = LibraryQuickFilter.fragments(query)
    if let memo = quickFilterMemo, memo.stateRevision == stateRevision, memo.fragments == fragments {
      return memo.result
    }

    let items: [ItemSummary]
    switch state {
    case .loaded(let rows), .partiallySynced(let rows), .staleOffline(let rows): items = rows
    case .loading, .empty, .error, .filteredEmpty: items = []
    }
    let result: [ItemSummary]
    if fragments.isEmpty {
      result = items
    } else {
      let keys = titleSearchKeys.keys(for: items)
      result = zip(items, keys).compactMap { item, key in
        LibraryQuickFilter.matches(fragments: fragments, searchKey: key) ? item : nil
      }
    }
    quickFilterMemo = QuickFilterMemo(stateRevision: stateRevision, fragments: fragments, result: result)
    return result
  }

  var titleSearchKeyComputations: Int { titleSearchKeys.computedKeyCount }

  // MARK: - Filter intents

  /// Each intent preserves every dimension it does not name, persists, and only then starts the
  /// replacement observation, all of which falls out of assigning `filters`.
  public func updateMediaFilter(_ media: MediaFilter) {
    filters = BrowseFilters(
      categories: media.browseCategories, downloadedOnly: filters.downloadedOnly,
      playback: filters.playback)
  }

  /// Sets the complete media-kind selection while preserving the status dimensions. An empty
  /// selection is canonicalized by `BrowseFilters` to the unfiltered media dimension.
  public func updateMediaCategories(_ categories: Set<ItemMediaCategory>?) {
    filters = BrowseFilters(
      categories: categories, downloadedOnly: filters.downloadedOnly, playback: filters.playback)
  }

  /// Whether a kind's row in the funnel reads as checked. No constraint (`nil`) shows nothing
  /// checked rather than everything: unchecking the last kind canonicalizes straight back to
  /// `nil`, so an all-checked state would bounce under the reader's finger.
  public func isMediaCategorySelected(_ category: ItemMediaCategory) -> Bool {
    filters.categories?.contains(category) ?? false
  }

  /// The additive media selection's intent: the funnel's rows are `Toggle`s over this set, so
  /// membership lives here rather than in a view rebuilding a `BrowseFilters` per tap. Unchecking
  /// the last kind leaves an empty set, which `BrowseFilters` canonicalizes to "no constraint".
  public func setMediaCategory(_ category: ItemMediaCategory, isOn: Bool) {
    var categories = filters.categories ?? []
    if isOn {
      categories.insert(category)
    } else {
      categories.remove(category)
    }
    updateMediaCategories(categories)
  }

  public func updateDownloadedOnly(_ downloadedOnly: Bool) {
    filters = BrowseFilters(
      categories: filters.categories, downloadedOnly: downloadedOnly, playback: filters.playback)
  }

  public func updatePlayback(_ playback: PlaybackFilter) {
    filters = BrowseFilters(
      categories: filters.categories, downloadedOnly: filters.downloadedOnly, playback: playback)
  }

  /// The escape hatch behind the filtered-empty state: clearing removes the stored key entirely, so
  /// a cleared filter and a fresh install are the same state on disk.
  public func clearFilters() {
    filters = .unfiltered
  }

  /// Pull-to-refresh: forwards to `SyncCoordinating.refresh()`. This model never talks to
  /// `ABSApi` directly (ARCHITECTURE.md).
  public func refresh() async {
    await sync.refresh()
  }

  /// Suppresses replacement of the rendered projection while the Library's scroll view is moving.
  /// Written by the Library root from `onScrollPhaseChange`; never read from a SwiftUI body.
  public func setPresentationDeferred(_ deferred: Bool) {
    guard presentationDeferred != deferred else { return }
    presentationDeferred = deferred

    guard deferred == false, presentationUpdatePending else { return }
    presentationUpdatePending = false
    recomputeState()
  }

  private func subscribe(filters: BrowseFilters) {
    latestSnapshot = nil
    latestStatus = nil
    presentationUpdatePending = false
    generationHasPublished = false
    let generation = filterObservations.begin(sourceCount: 2)

    // Subscribed synchronously, not inside a `Task`, so the observation starts now rather than
    // whenever the scheduler runs it. That also makes a fake's first pushed value deterministic.
    // The status stream spans every library too, so "still syncing"/"stale offline" describe the
    // merged list rather than one library inside it.
    let itemsStream = library.observeBrowseList(filters: filters)
    let statusStream = library.observeAggregateSyncStatus()

    filterObservations.observe(itemsStream, sourceID: 0, in: generation) {
      [weak self] snapshot, ready in
      guard let self else { return }
      self.latestSnapshot = snapshot
      if ready { self.recomputeState() }
    }
    filterObservations.observe(statusStream, sourceID: 1, in: generation) {
      [weak self] status, ready in
      guard let self else { return }
      self.latestStatus = status
      if ready { self.recomputeState() }
    }
  }

  private func recomputeState() {
    guard let snapshot = latestSnapshot, let status = latestStatus else {
      return
    }

    if presentationDeferred && generationHasPublished && state.hasRenderableProjection {
      presentationUpdatePending = true
      LibraryRefreshPerfTrace.emit(.projection(.deferred, items: snapshot.items.count))
      return
    }

    let items = snapshot.items
    let nextState: State
    if status.isRunning {
      // A run with nothing cached at all is a first fill, not a partial one. `.partiallySynced([])`
      // renders no rows, placeholder or copy, so `.loading` is used to fill the space the rows
      // will occupy. The unfiltered count separates this from a filter that currently matches
      // nothing, which keeps `.partiallySynced` so a filtered-empty view does not flip to
      // "loading" for the length of every background run.
      nextState =
        items.isEmpty && snapshot.hasUnfilteredItems == false
        ? .loading : .partiallySynced(items)
    } else {
      // Ahead of the incomplete-run branch: cached rows exist, so "couldn't load" would be false
      // and the reader needs the filter named rather than the network blamed. An in-flight sync
      // still wins above, as the list may yet fill.
      if items.isEmpty, snapshot.hasUnfilteredItems, filters.isActive {
        nextState = .filteredEmpty
      } else if status.lastRunIncomplete {
        if items.isEmpty {
          nextState = .error
        } else if AppModelStaleness.isStale(
          lastCompletedAt: status.lastCompletedAt, now: clock.now(), staleAfter: staleAfter)
        {
          nextState = .staleOffline(items)
        } else {
          // A recent failed refresh with still-fresh cached data: keep the plain loaded view
          // rather than alarming the user over one blip.
          nextState = .loaded(items)
        }
      } else {
        nextState = items.isEmpty ? .empty : .loaded(items)
      }
    }

    state = nextState
    generationHasPublished = true
    LibraryRefreshPerfTrace.emit(.projection(.published, items: items.count))
  }
}

extension LibraryBrowseModel.State {
  fileprivate var hasRenderableProjection: Bool {
    switch self {
    case .loading, .empty, .error, .filteredEmpty:
      return false
    case .loaded, .partiallySynced, .staleOffline:
      return true
    }
  }
}

/// The single-kind vocabulary's mapping onto the shared composite category set. Home uses
/// `MediaFilter` as it is. Multi-kind Library selections are represented directly by
/// `BrowseFilters.categories`.
extension MediaFilter {
  public var browseCategories: Set<ItemMediaCategory>? {
    category.map { [$0] }
  }

  public init(browseCategories: Set<ItemMediaCategory>?) {
    guard let browseCategories, browseCategories.count == 1, let only = browseCategories.first,
      let match = MediaFilter.allCases.first(where: { $0.category == only })
    else {
      self = .all
      return
    }
    self = match
  }
}

extension LibraryBrowseModel.State {
  /// A stable identifier for the copy this state renders, so tests can pin each state's copy.
  /// `.loaded` renders items directly and carries no banner copy.
  public var copyKey: String {
    switch self {
    case .loading: return "browse.loading"
    case .empty: return "browse.empty"
    case .loaded: return "browse.loaded"
    case .partiallySynced: return "browse.partiallySynced"
    case .error: return "browse.error"
    case .staleOffline: return "browse.staleOffline"
    case .filteredEmpty: return "browse.filteredEmpty"
    }
  }

  /// Whether this state offers Clear Filters. Only the state a filter caused does, so the escape
  /// hatch never appears where it would do nothing.
  public var offersClearFilters: Bool {
    if case .filteredEmpty = self { return true }
    return false
  }

  /// The literal copy a screen renders for this state's banner. Empty for `.loaded`, which has
  /// nothing to say beyond the rendered rows.
  ///
  /// Takes the active `filters` so states naming the list's contents name the selected media
  /// type(s), not "No books yet" for an empty podcast list. The unfiltered tab merges every
  /// library and names none.
  public func copyText(for filters: BrowseFilters) -> String {
    switch self {
    case .loading:
      return "Loading your library…"
    case .empty:
      guard let noun = LibraryFilterCopy.mediaPluralNoun(for: filters.categories) else {
        return "Nothing synced yet. Pull to sync your library."
      }
      return "No \(noun) in your library. Pull to refresh, or pick another media type."
    case .loaded:
      return ""
    case .partiallySynced:
      let noun = LibraryFilterCopy.mediaPluralNoun(for: filters.categories) ?? "titles"
      return "Still syncing your library — more \(noun) will appear as they finish."
    case .error:
      return "Couldn't load your library. Check your connection and try again."
    case .staleOffline:
      return "Showing your last synced library. We can't reach the server right now."
    case .filteredEmpty:
      return LibraryFilterCopy.filteredEmptyMessage(for: filters)
    }
  }

  /// The heading over the list, for the two states that render one. Filtered-empty gets its own
  /// title so it cannot be mistaken for `MediaFilterCopy.emptyTitle`'s "Your Library Is Empty".
  public func emptyTitle(for filters: BrowseFilters) -> String {
    switch self {
    case .filteredEmpty:
      return LibraryFilterCopy.filteredEmptyTitle(for: filters)
    default:
      return LibraryFilterCopy.emptyTitle(for: filters)
    }
  }
}
