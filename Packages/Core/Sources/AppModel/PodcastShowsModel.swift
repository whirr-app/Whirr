import Foundation
import Observation
import Persistence
import SyncEngine

public enum PodcastShowsCopy {
  public static let loading = "Loading your shows…"
  public static let empty = "No podcasts yet. Pull to refresh."
  public static let partiallySynced = "Still syncing — more shows will appear as they finish."
  public static let error = "Couldn't load your shows. Check your connection and try again."
  public static let staleOffline =
    "Showing your last synced shows. We can't reach the server right now."
  public static let reorderFailed = ShowOrderingPolicy.reorderFailed
  public static let resetFailed = ShowOrderingPolicy.resetFailed
}

/// Your Shows' ordered surface, shared by the Podcasts-root preview and the all-shows page so the
/// two cannot grow different sort rules.
///
/// The snapshot arrives ordered from `PodcastShowOrdering`. This model combines it with the
/// aggregate sync status and reorders ids on the way out to a mutation, but never sorts a custom
/// order itself. A failed mutation gets no optimistic order: the sequence stays as last observed.
@MainActor
@Observable
public final class PodcastShowsModel {
  public enum State: Sendable, Equatable {
    /// Neither the ordering nor the sync-status observation has emitted its first value yet.
    case loading
    /// No shows, and nothing is syncing or has ever failed to sync.
    case empty
    case loaded(PodcastShowsSnapshot)
    /// A sync run is in progress: the shows so far, with editing off. A show arriving mid-drag
    /// would invalidate the "full visible sequence" being committed.
    case partiallySynced(PodcastShowsSnapshot)
    case error
    case staleOffline(PodcastShowsSnapshot)

    var snapshot: PodcastShowsSnapshot? {
      switch self {
      case .loaded(let snapshot), .partiallySynced(let snapshot), .staleOffline(let snapshot):
        return snapshot
      case .loading, .empty, .error:
        return nil
      }
    }

    public var copyText: String {
      switch self {
      case .loading: PodcastShowsCopy.loading
      case .empty: PodcastShowsCopy.empty
      case .loaded: ""
      case .partiallySynced: PodcastShowsCopy.partiallySynced
      case .error: PodcastShowsCopy.error
      case .staleOffline: PodcastShowsCopy.staleOffline
      }
    }
  }

  public private(set) var state: State = .loading
  public private(set) var actionErrorMessage: String?

  public var shows: [ItemSummary] { state.snapshot?.shows ?? [] }
  public var sortMode: PodcastShowSortMode { state.snapshot?.mode ?? .alphabetical }

  /// Editing needs a stable snapshot to commit in full, which every state except a running sync
  /// either has or has nothing to arrange.
  public var isEditingAllowed: Bool {
    switch state {
    case .loaded, .staleOffline: true
    case .loading, .empty, .partiallySynced, .error: false
    }
  }

  private let ordering: any PodcastShowOrdering
  private let library: any LibraryReading
  private let sync: any SyncCoordinating
  private let clock: any SyncClock
  private let staleAfter: TimeInterval

  private var latestSnapshot: PodcastShowsSnapshot?
  private var latestStatus: LibrarySyncStatus?

  /// Shared with `HomeModel`/`LibraryBrowseModel`: keeps the two observations on one lifecycle,
  /// publishes them as one ready generation, and drops values from a superseded subscription.
  @ObservationIgnored private var observations = FilterObservationCoordinator()

  public init(
    ordering: any PodcastShowOrdering = NoOpPodcastShowOrdering(),
    library: any LibraryReading,
    sync: any SyncCoordinating,
    clock: any SyncClock = SystemSyncClock(),
    staleAfter: TimeInterval = AppModelStaleness.defaultStaleAfter
  ) {
    self.ordering = ordering
    self.library = library
    self.sync = sync
    self.clock = clock
    self.staleAfter = staleAfter

    subscribe()
  }

  /// Pull-to-refresh: forwards to `SyncCoordinating.refresh()`. This model never talks to
  /// `ABSApi` directly (ARCHITECTURE.md §2).
  public func refresh() async {
    await sync.refresh()
  }

  public func preview(limit: Int) -> [ItemSummary] {
    ShowOrderingPolicy.preview(shows, limit: limit)
  }

  /// Moves `itemID` to `destination` in the visible sequence, clamped into range, and commits the
  /// whole resulting sequence. Drag and the accessibility move actions both land here.
  public func move(itemID: String, to destination: Int) async {
    await apply(
      order: ShowOrderingPolicy.reorder(shows.map(\.serverItemId), moving: itemID, to: destination))
  }

  /// The single mutation funnel: every reorder entry point reduces to one already-computed id
  /// sequence and one `replaceCustomOrder` call. A sequence identical to the observed one is not
  /// a move, so it writes nothing.
  public func apply(order itemIDs: [String]) async {
    guard itemIDs != shows.map(\.serverItemId) else { return }
    do {
      try await ordering.replaceCustomOrder(itemIDs: itemIDs)
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = PodcastShowsCopy.reorderFailed
    }
  }

  public func resetToAlphabetical() async {
    do {
      try await ordering.resetToAlphabetical()
      actionErrorMessage = nil
    } catch {
      actionErrorMessage = PodcastShowsCopy.resetFailed
    }
  }

  public func dismissActionError() {
    actionErrorMessage = nil
  }

  /// Internal so a test can supersede the live generation; production composes one model per
  /// account and never re-arms it.
  func subscribe() {
    latestSnapshot = nil
    latestStatus = nil
    let generation = observations.begin(sourceCount: 2)

    // Subscribed synchronously here, not inside the coordinator's `Task`s, so the observation
    // starts now rather than whenever the scheduler runs it.
    let showsStream = ordering.observeShows()
    let statusStream = library.observeAggregateSyncStatus()

    observations.observe(showsStream, sourceID: 0, in: generation) { [weak self] snapshot, ready in
      guard let self else { return }
      self.latestSnapshot = snapshot
      if ready { self.recomputeState() }
    }
    observations.observe(statusStream, sourceID: 1, in: generation) { [weak self] status, ready in
      guard let self else { return }
      self.latestStatus = status
      if ready { self.recomputeState() }
    }
  }

  private func recomputeState() {
    guard let snapshot = latestSnapshot, let status = latestStatus else { return }

    if status.isRunning {
      state = .partiallySynced(snapshot)
      return
    }

    if status.lastRunIncomplete {
      if snapshot.shows.isEmpty {
        state = .error
      } else if AppModelStaleness.isStale(
        lastCompletedAt: status.lastCompletedAt, now: clock.now(), staleAfter: staleAfter)
      {
        state = .staleOffline(snapshot)
      } else {
        // A recent failed refresh over still-fresh shows: keep the plain loaded view rather than
        // alarming the user over one blip.
        state = .loaded(snapshot)
      }
      return
    }

    state = snapshot.shows.isEmpty ? .empty : .loaded(snapshot)
  }
}
