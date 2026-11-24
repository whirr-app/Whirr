import ABSApi
import AppModel
import DesignSystem
import Foundation
import Observation
import Persistence
import SwiftUI

/// Per-screen observable projection over the shell's `CoverPaletteService`.
///
/// Owns only request batching, scroll-deferred publication and the dictionary a view reads.
/// Record lookup, artwork waiting, extraction, persistence, and cross-screen coalescing all
/// belong to the service.
@MainActor
@Observable
final class HomeWashProvider: CoverPaletteServiceObserver {
  /// A bulk request is background work until a visible request for the same cover upgrades it.
  enum RequestIntent: Sendable, Equatable {
    case bulk
    case visible
  }
  private static let maximumConcurrentResolutions = 4

  struct ScrollSource: Hashable, Sendable {
    enum ID: Hashable, Sendable {
      case homeOuter
      case homeRail(HomeMoreSection)
      case podcastsOuter
      case allShowsOuter
      case authorSeriesOuter
    }

    let id: ID
    let generation: UUID
  }

  private struct PendingRequest: Hashable, Sendable {
    var intent: RequestIntent
    var displaySize: CGFloat
    var displayScale: CGFloat
    var artworkRole: CoverImageView.Role
    var artworkRevision: ArtworkRevision
    var artworkSource: ArtworkSource?
  }

  let service: CoverPaletteService
  var displaySize: CGFloat
  var displayScale: CGFloat
  var artworkRole: CoverImageView.Role

  private(set) var washes: [String: CoverWash] = [:]

  @ObservationIgnored private var pending: [String: PendingRequest] = [:]
  @ObservationIgnored private var active: [String: PendingRequest] = [:]
  @ObservationIgnored private var washRevisions: [String: ArtworkRevision] = [:]
  @ObservationIgnored private var washSources: [String: ArtworkSource] = [:]
  /// What each item was last asked for, a visible request sticky over a bulk one, so a cache
  /// clear can re-derive every card already on the screen without waiting for rows to reappear.
  @ObservationIgnored private var knownRequests: [String: PendingRequest] = [:]
  /// Bumped by a service clear; a preload that straddles one publishes nothing.
  @ObservationIgnored private var clearGeneration = 0
  @ObservationIgnored private var requestTask: Task<Void, Never>?
  @ObservationIgnored private var resolutionTasks: [String: Task<Void, Never>] = [:]
  /// Editorial colour is decorative and must not invalidate a scrolling card/list hierarchy.
  /// Resolution continues while the user directly controls the scroll; publication is coalesced
  /// until that direct interaction ends.
  @ObservationIgnored private var movingScrollSources: Set<ScrollSource> = []
  /// Generations live here, not in view `@State`: retirement fires from lazy-row `onDisappear`
  /// mid-scroll, and writing a generation into observed view state re-evaluates the whole screen
  /// once per rail leaving the viewport.
  @ObservationIgnored private var scrollSourceGenerations: [ScrollSource.ID: UUID] = [:]
  @ObservationIgnored private var deferredWashes: [String: CoverWash] = [:]
  @ObservationIgnored private var pendingResolvedWashes: [String: CoverWash] = [:]
  @ObservationIgnored private var pendingIdleWashes: [String: CoverWash] = [:]
  @ObservationIgnored private var hasPendingResolution = false
  @ObservationIgnored private var publicationTask: Task<Void, Never>?
  @ObservationIgnored private let onWashesMutated: (@MainActor @Sendable () -> Void)?
  @ObservationIgnored private let onBatchResolved: (@MainActor @Sendable ([String: CoverWash]) -> Void)?

  init(
    service: CoverPaletteService,
    displaySize: CGFloat,
    displayScale: CGFloat,
    artworkRole: CoverImageView.Role = .homeCard,
    onWashesMutated: (@MainActor @Sendable () -> Void)? = nil,
    onBatchResolved: (@MainActor @Sendable ([String: CoverWash]) -> Void)? = nil
  ) {
    self.service = service
    self.displaySize = displaySize
    self.displayScale = displayScale
    self.artworkRole = artworkRole
    self.onWashesMutated = onWashesMutated
    self.onBatchResolved = onBatchResolved
    service.addObserver(self)
  }

  /// Stable for a scroll host's whole on-screen life, fresh after retirement. A host captures its
  /// source once per materialization; the generation lets a late retire from a replaced host
  /// instance miss its live successor instead of silencing it.
  func scrollSource(for id: ScrollSource.ID) -> ScrollSource {
    if let generation = scrollSourceGenerations[id] {
      return ScrollSource(id: id, generation: generation)
    }
    let generation = UUID()
    scrollSourceGenerations[id] = generation
    return ScrollSource(id: id, generation: generation)
  }

  /// These shelves share one entry in the artwork gate: a cover revalidation is suppressed when
  /// anything is moving, and every surface this provider serves scrolls covers.
  private static let artworkScrollSource = "homeWash"

  func setScrollInteractionActive(_ phase: ScrollPhase, source: ScrollSource) {
    harnessNote(.scrollPhaseChange)
    if HarnessSwitch.skipsScrollPhaseTracking { return }
    let wasDeferred = movingScrollSources.isEmpty == false
    if Self.shouldDeferPublication(for: phase) {
      movingScrollSources.insert(source)
      if wasDeferred == false, pendingIdleWashes.isEmpty == false {
        deferredWashes.merge(pendingIdleWashes) { _, newWash in newWash }
        pendingIdleWashes.removeAll(keepingCapacity: true)
      }
    } else {
      movingScrollSources.remove(source)
    }

    ArtworkScrollActivity.shared.setScrolling(
      movingScrollSources.isEmpty == false, source: Self.artworkScrollSource)

    if wasDeferred, movingScrollSources.isEmpty {
      publishDeferredWashes()
    }
  }

  func retireScrollSource(_ source: ScrollSource) {
    let wasDeferred = movingScrollSources.isEmpty == false
    movingScrollSources.remove(source)
    if scrollSourceGenerations[source.id] == source.generation {
      scrollSourceGenerations[source.id] = UUID()
    }
    ArtworkScrollActivity.shared.setScrolling(
      movingScrollSources.isEmpty == false, source: Self.artworkScrollSource)

    if wasDeferred, movingScrollSources.isEmpty {
      publishDeferredWashes()
    }
  }

  func retireAllScrollSources() {
    let wasDeferred = movingScrollSources.isEmpty == false
    movingScrollSources.removeAll(keepingCapacity: true)
    scrollSourceGenerations.removeAll(keepingCapacity: true)
    ArtworkScrollActivity.shared.setScrolling(false, source: Self.artworkScrollSource)
    if wasDeferred {
      publishDeferredWashes()
    }
  }

  static func shouldDeferPublication(for phase: ScrollPhase) -> Bool {
    switch phase {
    // A fling is a moment of tracking followed by seconds of deceleration. Publishing while the
    // list is still moving invalidates every wash-reading row mid-fling, so publication waits for
    // the scroll to settle at idle.
    case .tracking, .interacting, .decelerating, .animating:
      true
    case .idle:
      false
    @unknown default:
      true
    }
  }

  /// One batched records-only read for a page's items, published as a single dictionary mutation.
  /// Called on page appear, so every already-extracted item is colored from the first frame
  /// instead of trickling through the concurrency-limited resolution path one publication at a
  /// time. Misses are left untouched for the lazy `request` path.
  func preloadCachedWashes(_ subjects: [EditorialWashSubject]) async {
    let sourcesByID = subjects.sourcesByID
    let revisionsByID = subjects.revisionsByID
    let generation = clearGeneration
    let cached = await service.cachedWashes(
      itemIDs: subjects.itemIDs, revisionsByID: revisionsByID, sourcesByID: sourcesByID)
    guard Task.isCancelled == false, generation == clearGeneration else { return }
    adopt(cached, sourcesByID: sourcesByID, revisionsByID: revisionsByID)
  }

  /// The synchronous half of `preloadCachedWashes`: only what the shell's service already
  /// holds in memory, so a grid appearing for the first time can colour its cards in the update
  /// that draws them rather than a records read later.
  func seedCachedWashes(_ subjects: [EditorialWashSubject]) {
    let sourcesByID = subjects.sourcesByID
    let revisionsByID = subjects.revisionsByID
    let cached = service.memoryCachedWashes(
      itemIDs: subjects.itemIDs, revisionsByID: revisionsByID, sourcesByID: sourcesByID)
    adopt(cached, sourcesByID: sourcesByID, revisionsByID: revisionsByID)
  }

  /// Skips a wash this screen already shows for the same artwork, so a seed followed by the page's
  /// preload, or a grid re-appearing on a later scroll pass, is not a second mutation.
  private func adopt(
    _ candidates: [String: CoverWash],
    sourcesByID: [String: ArtworkSource],
    revisionsByID: [String: ArtworkRevision]
  ) {
    let cached = candidates.filter { itemID, wash in
      washes[itemID] != wash
        || washRevisions[itemID] != (revisionsByID[itemID] ?? .unversioned)
        || washSources[itemID] != sourcesByID[itemID]
    }
    guard cached.isEmpty == false else { return }
    for itemID in cached.keys {
      if knownRequests[itemID] == nil {
        knownRequests[itemID] = PendingRequest(
          intent: .bulk, displaySize: displaySize, displayScale: displayScale,
          artworkRole: artworkRole, artworkRevision: revisionsByID[itemID] ?? .unversioned,
          artworkSource: sourcesByID[itemID])
      }
      resolutionTasks[itemID]?.cancel()
      resolutionTasks[itemID] = nil
      active[itemID] = nil
      pendingResolvedWashes[itemID] = nil
      washRevisions[itemID] = revisionsByID[itemID] ?? .unversioned
      washSources[itemID] = sourcesByID[itemID]
      pending[itemID] = nil
    }
    submitForPublication(cached)
    publishSubmittedWashes()
    startBatchIfNeeded()
  }

  /// The wash a view paints for `subject` right now: neutral until the subject resolves, and
  /// neutral for good when its cover yields no colour. `EditorialWashedCard` is the ordinary
  /// reader; a page palette reads here directly.
  func wash(for subject: EditorialWashSubject) -> CoverWash {
    washes[subject.itemID] ?? .drainedNeutral
  }

  /// Requests take subjects, not ids: an `rss:` id that arrives without its artwork source is a
  /// feed with no artwork, and is skipped below as one. Multiple appearance callbacks coalesce
  /// into one admission pass; a visible request upgrades a queued or active bulk request for its
  /// item.
  func request(
    _ subjects: [EditorialWashSubject],
    intent: RequestIntent = .visible,
    displaySize: CGFloat? = nil,
    displayScale: CGFloat? = nil,
    artworkRole: CoverImageView.Role? = nil
  ) {
    let itemIDs = subjects.itemIDs
    let sourcesByID = subjects.sourcesByID
    let revisionsByID = subjects.revisionsByID
    harnessNote(intent == .visible ? .washRequestVisible : .washRequestBulk)
    harnessNote(.washRequestedItems, itemIDs.count)
    if let displaySize { self.displaySize = displaySize }
    if let displayScale { self.displayScale = displayScale }
    if let artworkRole { self.artworkRole = artworkRole }

    var staleItemIDs: [String] = []
    for itemID in Self.unique(itemIDs) {
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil, sourcesByID[itemID] == nil {
        continue
      }
      let request = PendingRequest(
        intent: intent,
        displaySize: displaySize ?? self.displaySize,
        displayScale: displayScale ?? self.displayScale,
        artworkRole: artworkRole ?? self.artworkRole,
        artworkRevision: revisionsByID[itemID] ?? .unversioned,
        artworkSource: sourcesByID[itemID])
      var known = request
      if knownRequests[itemID]?.intent == .visible { known.intent = .visible }
      knownRequests[itemID] = known
      if washRevisions[itemID] == request.artworkRevision,
        washSources[itemID] == request.artworkSource
      {
        continue
      }
      if washRevisions[itemID] != nil || washSources[itemID] != nil {
        deferredWashes[itemID] = nil
        pendingResolvedWashes[itemID] = nil
        pendingIdleWashes[itemID] = nil
        staleItemIDs.append(itemID)
      }
      if let activeRequest = active[itemID] {
        if activeRequest.artworkRevision != request.artworkRevision {
          pending[itemID] = request
        } else if activeRequest.intent == .bulk, intent == .visible {
          pending[itemID] = request
        }
        continue
      }
      if let pendingRequest = pending[itemID] {
        if pendingRequest.artworkRevision != request.artworkRevision {
          pending[itemID] = request
        } else if pendingRequest.intent == .visible || intent == .visible {
          pending[itemID] = request
          pending[itemID]?.intent = .visible
        }
      } else {
        pending[itemID] = request
      }
    }
    publish(removing: staleItemIDs)
    startBatchIfNeeded()
  }

  /// Called after a clear: everything held (published washes, pending results, resolutions in
  /// flight) came from the cleared artwork and is discarded, and every requested item is queued
  /// again with its last request. The request and publication tasks keep running: each clears its
  /// own slot when it runs, so cancelling one would let it retire its successor's slot.
  func paletteServiceDidClear() {
    clearGeneration += 1
    for task in resolutionTasks.values {
      task.cancel()
    }
    resolutionTasks.removeAll()
    active.removeAll()
    washRevisions.removeAll()
    washSources.removeAll()
    deferredWashes.removeAll()
    pendingResolvedWashes.removeAll()
    pendingIdleWashes.removeAll()
    hasPendingResolution = false
    pending = knownRequests
    if washes.isEmpty == false {
      washes = [:]
      onWashesMutated?()
    }
    startBatchIfNeeded()
  }

  /// Called by the service when another path (a player, item detail, the backfill, or a row it
  /// followed) answers a cover a request left without a palette. Only a card still neutral for that
  /// same artwork takes it: a settled card is never recoloured, a request since made for other
  /// artwork wins, and a player's provisional answer is not a card's.
  func paletteServiceDidAnswer(_ answered: [CoverPaletteIdentity: CoverPalette]) {
    var adopted: [String: CoverWash] = [:]
    var sourcesByID: [String: ArtworkSource] = [:]
    var revisionsByID: [String: ArtworkRevision] = [:]
    for (identity, palette) in answered where identity.isProvisional == false {
      let itemID = identity.itemID
      guard washes[itemID] == nil, washRevisions[itemID] == nil,
        let request = knownRequests[itemID],
        service.cardIdentity(
          itemID: itemID, revision: request.artworkRevision, source: request.artworkSource)
          == identity
      else { continue }
      adopted[itemID] = CoverPaletteService.wash(from: palette)
      sourcesByID[itemID] = request.artworkSource
      revisionsByID[itemID] = request.artworkRevision
    }
    guard adopted.isEmpty == false else { return }
    adopt(adopted, sourcesByID: sourcesByID, revisionsByID: revisionsByID)
  }

  private func startBatchIfNeeded() {
    guard requestTask == nil, pending.isEmpty == false else { return }
    requestTask = Task { @MainActor [weak self] in
      // SwiftUI commonly invokes several row `onAppear` callbacks in one update. This suspension
      // gives the provider a chance to collect that update into one request/publication.
      await Task.yield()
      guard Task.isCancelled == false else {
        self?.requestTask = nil
        return
      }
      guard let self else { return }
      self.requestTask = nil
      self.startAvailableResolutions()
    }
  }

  private struct ResolutionWork {
    let itemID: String
    let request: PendingRequest
    let service: CoverPaletteService
  }

  private func startAvailableResolutions() {
    while resolutionTasks.count < Self.maximumConcurrentResolutions {
      // Active work is not pre-empted. Once a slot is free, visible work wins, and
      // item ID order makes selection deterministic within an intent.
      let activeRequests = active
      guard
        let next = pending.lazy
          .filter({ activeRequests[$0.key] == nil })
          .min(by: {
            let leftPriority = $0.value.intent == .visible ? 0 : 1
            let rightPriority = $1.value.intent == .visible ? 0 : 1
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            return $0.key < $1.key
          })
      else { return }
      let itemID = next.key
      let request = next.value
      pending[itemID] = nil
      active[itemID] = request

      let work = ResolutionWork(itemID: itemID, request: request, service: service)
      let task = Task { @MainActor [weak self, work] in
        let wash = await Self.resolve(work: work)
        guard Task.isCancelled == false else { return }
        guard let self else { return }
        self.finishResolution(work: work, wash: wash)
      }
      resolutionTasks[itemID] = task
    }
  }

  private static func resolve(work: ResolutionWork) async -> CoverWash? {
    let result = await work.service.resolveWashes(
      itemIDs: [work.itemID],
      displaySize: work.request.displaySize,
      displayScale: work.request.displayScale,
      artworkRole: work.request.artworkRole,
      intent: work.request.intent,
      revisionsByID: [work.itemID: work.request.artworkRevision],
      sourcesByID: work.request.artworkSource.map { [work.itemID: $0] } ?? [:])
    return result[work.itemID]
  }

  private func finishResolution(work: ResolutionWork, wash: CoverWash?) {
    guard active[work.itemID] == work.request else { return }
    active[work.itemID] = nil
    resolutionTasks[work.itemID] = nil

    let hasRevisionReplacement =
      pending[work.itemID].map {
        $0.artworkRevision != work.request.artworkRevision
      } ?? false
    if hasRevisionReplacement == false {
      if let wash {
        washRevisions[work.itemID] = work.request.artworkRevision
        washSources[work.itemID] = work.request.artworkSource
        if pending[work.itemID]?.artworkRevision == work.request.artworkRevision {
          pending[work.itemID] = nil
        }
        pendingResolvedWashes[work.itemID] = wash
        submitForPublication([work.itemID: wash])
      }
    }

    hasPendingResolution = true
    schedulePublication()
    startBatchIfNeeded()
  }

  private func schedulePublication() {
    guard publicationTask == nil else { return }
    publicationTask = Task { @MainActor [weak self] in
      // One suspension coalesces a burst of same-tick completions without waiting for later work.
      await Task.yield()
      guard Task.isCancelled == false else {
        self?.publicationTask = nil
        return
      }
      guard let self else { return }
      self.publicationTask = nil
      self.publishResolvedWashes()
    }
  }

  private func publishResolvedWashes() {
    guard hasPendingResolution else { return }
    let resolved = pendingResolvedWashes
    pendingResolvedWashes.removeAll(keepingCapacity: true)
    hasPendingResolution = false

    publishSubmittedWashes()
    onBatchResolved?(resolved)

    if hasPendingResolution {
      schedulePublication()
    }
  }

  private func publishDeferredWashes() {
    if pendingIdleWashes.isEmpty == false {
      deferredWashes.merge(pendingIdleWashes) { _, newWash in newWash }
      pendingIdleWashes.removeAll(keepingCapacity: true)
    }
    guard deferredWashes.isEmpty == false else { return }
    let batch = deferredWashes
    deferredWashes.removeAll(keepingCapacity: true)
    publish(batch)
  }

  /// The only boundary through which a resolved wash enters publication. Results are merged while
  /// a scroll host is moving and are drained as one dictionary mutation once every host settles.
  private func submitForPublication(_ batch: [String: CoverWash]) {
    guard batch.isEmpty == false else { return }
    if movingScrollSources.isEmpty {
      pendingIdleWashes.merge(batch) { _, newWash in newWash }
    } else {
      deferredWashes.merge(batch) { _, newWash in newWash }
    }
  }

  private func publishSubmittedWashes() {
    guard movingScrollSources.isEmpty, pendingIdleWashes.isEmpty == false else { return }
    let batch = pendingIdleWashes
    pendingIdleWashes.removeAll(keepingCapacity: true)
    publish(batch)
  }

  private func publish(_ batch: [String: CoverWash]) {
    if HarnessSwitch.skipsWashPublication { return }
    harnessNote(.washPublish)
    harnessNote(.washPublishedItems, batch.count)
    washes = washes.merging(batch) { _, newWash in newWash }
    onWashesMutated?()
  }

  private func publish(removing itemIDs: [String]) {
    var next = washes
    for itemID in itemIDs {
      next[itemID] = nil
    }
    guard next != washes else { return }
    washes = next
    onWashesMutated?()
  }

  private static func unique(_ itemIDs: [String]) -> [String] {
    var seen = Set<String>()
    return itemIDs.filter { seen.insert($0).inserted }
  }

  isolated deinit {
    requestTask?.cancel()
    publicationTask?.cancel()
    for task in resolutionTasks.values {
      task.cancel()
    }
  }
}
