import Observation
import Persistence
import SyncEngine

/// The item detail screen's History section. Cache-then-refresh: cached entries surface at once
/// from `ListeningHistoryProviding.cachedListeningHistory` (no network), then a background
/// `refreshListeningHistory` updates them. A refresh failure keeps the cached entries and sets
/// `isStale`; construction never awaits network I/O. Overlapping explicit refreshes coalesce onto
/// the running operation, except one arriving during `init`'s drain-less walk, which waits and
/// then runs a drained refresh of its own.
@MainActor
@Observable
public final class ItemHistoryModel {
  /// Cached entries, newest session first. Empty until the first cache read completes.
  public private(set) var entries: [ListeningHistoryEntry] = []
  /// `true` once a refresh attempt has completed unsuccessfully and no successful refresh has
  /// happened since. Starts `false`: before the first refresh result arrives, cached entries
  /// (however old) are shown without a staleness claim.
  public private(set) var isStale = false

  /// `false` for an ebook-only item or while a cold detail route is resolving its category.
  /// Reading an EPUB opens no play session, so the model then does no work instead of paging the
  /// account's whole session history to filter it to nothing.
  public private(set) var tracksListeningHistory: Bool

  private let itemId: String
  private let history: any ListeningHistoryProviding
  private let uploadDrain: @Sendable () async -> Void

  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshInFlight = false
  /// Bumped when a new walk starts or `updateCategory` invalidates the current one. The provider
  /// may ignore cancellation, so every publish and completion step checks its own generation, or a
  /// superseded walk could republish entries the ebook flip cleared.
  @ObservationIgnored private var refreshGeneration = 0
  /// Whether the in-flight operation ran the upload drain. `init`'s does not (launch/foreground
  /// already drain), so a coalesced `refresh()` would skip the drain that surfaces a session that
  /// has only just finished; a caller arriving during a drain-less walk waits, then runs its own.
  @ObservationIgnored private var inFlightDrained = false

  public init(
    itemId: String,
    category: ItemMediaCategory?,
    history: any ListeningHistoryProviding,
    uploadDrain: @escaping @Sendable () async -> Void = {}
  ) {
    self.itemId = itemId
    self.history = history
    self.uploadDrain = uploadDrain
    tracksListeningHistory = category.map { $0 != .ebook } ?? false
    guard tracksListeningHistory else { return }

    // Kicked off in `init`, not awaited, so construction never blocks on network I/O. The cache
    // read and the refresh both happen inside this one fire-and-forget task.
    refreshTask = makeRefreshTask(
      itemId: itemId, history: history, uploadDrain: {}, readInitialCache: true, drains: false)
  }

  /// Supplies the category from the detail response after a cold route has finished resolving.
  /// An unknown category cannot safely default to audio: an ebook has no listening sessions, and
  /// its fallback request would otherwise page the account's entire history for no result.
  /// Idempotent through `tracksListeningHistory`, the one fact the category decides here.
  public func updateCategory(_ category: ItemMediaCategory) {
    let shouldTrack = category != .ebook
    guard tracksListeningHistory != shouldTrack else { return }

    tracksListeningHistory = shouldTrack
    guard shouldTrack else {
      refreshGeneration += 1
      refreshTask?.cancel()
      refreshTask = nil
      refreshInFlight = false
      entries = []
      isStale = false
      return
    }

    refreshTask = makeRefreshTask(
      itemId: itemId, history: history, uploadDrain: {}, readInitialCache: true, drains: false)
  }

  public func refresh() async {
    guard tracksListeningHistory else { return }
    if refreshInFlight {
      await refreshTask?.value
      // A drained walk covers this caller entirely. A drain-less one (only `init`'s) does not:
      // fall through and run a real refresh now that the previous operation has finished.
      if inFlightDrained { return }
      if refreshInFlight { return }
      // The wait can outlive the need: a category flip to ebook while awaiting leaves no history
      // to refresh, and a walk would repopulate what the flip cleared.
      guard tracksListeningHistory else { return }
    }

    refreshTask = makeRefreshTask(
      itemId: itemId, history: history, uploadDrain: uploadDrain, readInitialCache: false, drains: true)
    await refreshTask?.value
  }

  private func makeRefreshTask(
    itemId: String,
    history: any ListeningHistoryProviding,
    uploadDrain: @escaping @Sendable () async -> Void,
    readInitialCache: Bool,
    drains: Bool
  ) -> Task<Void, Never> {
    refreshInFlight = true
    inFlightDrained = drains
    refreshGeneration += 1
    let generation = refreshGeneration
    return Task { [weak self] in
      guard let self else { return }
      if readInitialCache {
        await self.publishCachedEntries(from: history, itemId: itemId, generation: generation)
      }

      await uploadDrain()
      let refreshed = await history.refreshListeningHistory(itemId: itemId) { [weak self] in
        guard let self else { return }
        await self.publishCachedEntries(from: history, itemId: itemId, generation: generation)
      }
      guard self.refreshGeneration == generation else { return }
      if refreshed {
        await self.publishCachedEntries(from: history, itemId: itemId, generation: generation)
        guard self.refreshGeneration == generation else { return }
        self.isStale = false
      } else {
        self.isStale = true
      }
      self.refreshInFlight = false
      self.refreshTask = nil
    }
  }

  private func publishCachedEntries(
    from history: any ListeningHistoryProviding, itemId: String, generation: Int
  ) async {
    let cached = await history.cachedListeningHistory(itemId: itemId)
    guard refreshGeneration == generation else { return }
    entries = cached
  }

  deinit {
    refreshTask?.cancel()
  }
}
