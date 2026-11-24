import ABSApi
import Foundation
import Persistence

/// The narrow cache boundary used by `CoverCacheAllCoordinator`. Presence checks are cache-only;
/// a miss never creates network traffic or consumes a cover-transfer permit.
public protocol CoverCacheFilling: Sendable {
  /// Cache-only, and reads no image bytes. Never creates traffic or consumes a transfer permit.
  func contains(_ key: ArtworkKey) async -> Bool

  /// Cache-only. A miss returns `nil`; this never creates traffic or consumes a transfer permit.
  /// The coordinator reads bytes only to measure a cover's shape, never as a presence test.
  func data(for key: ArtworkKey) async -> Data?

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult

  /// Removes covers nothing will ask for again; see `CoverImageClient.pruneCachedArtwork`.
  func pruneCachedArtwork(
    live: [String: ArtworkRevision], keep: [ArtworkKey], unlistedOlderThan: TimeInterval,
    byteCeiling: Int64, now: Date
  ) async -> CoverCachePruneSummary

  /// Deletes what is left of the cache an older build kept.
  func retireLegacyCache() async
}

extension CoverImageClient: CoverCacheFilling {}

public struct CoverCacheRunOutcome: Sendable, Equatable {
  public let fetched: Int
  public let alreadyPresent: Int
  public let failed: Int
  public let unavailable: Int
  public let finished: Bool

  public init(
    fetched: Int, alreadyPresent: Int, failed: Int, unavailable: Int = 0, finished: Bool
  ) {
    self.fetched = fetched
    self.alreadyPresent = alreadyPresent
    self.failed = failed
    self.unavailable = unavailable
    self.finished = finished
  }
}

public struct CoverCacheProgress: Sendable, Equatable {
  public let processed: Int
  /// Items that were not covered at the start of this pass and became fully covered during it.
  public let newlyCovered: Int
  public let total: Int
  public let isRunning: Bool

  public init(processed: Int, newlyCovered: Int, total: Int, isRunning: Bool) {
    self.processed = processed
    self.newlyCovered = newlyCovered
    self.total = total
    self.isRunning = isRunning
  }
}

/// What the bulk pass needs to measure each cover's shape and fetch its detail cover at the width
/// that shape needs. `pixelSize` reads an image's dimensions from its header; it is injected
/// because this target imports no image framework.
public struct CoverShapeMeasurement: Sendable {
  public let index: CoverShapeIndex
  public let sizing: DetailArtworkSizing
  public let pixelSize: @Sendable (Data) -> (width: Int, height: Int)?

  public init(
    index: CoverShapeIndex, sizing: DetailArtworkSizing,
    pixelSize: @escaping @Sendable (Data) -> (width: Int, height: Int)?
  ) {
    self.index = index
    self.sizing = sizing
    self.pixelSize = pixelSize
  }
}

/// Performs the automatic, account-wide cover-cache fill on an unconstrained foreground. Not a
/// heuristic artwork warm-up: it targets the keys used by library rows, detail/context-preview
/// surfaces, podcast episode rows, and podcast show cards, skips bytes already present per
/// variant, and can be repeated safely after cancellation or an OS cache purge.
public actor CoverCacheAllCoordinator: CoalescedPassHost {
  let accountDAO: AccountDAO
  let itemDAO: ItemDAO
  let covers: any CoverCacheFilling
  /// The resolved pixel width for the canonical library-row thumbnail key. App composition must
  /// pass `ArtworkVariant.libraryThumbnail(displaySize: 44, displayScale: scale).pixelWidth` so
  /// this UIKit-free coordinator warms the exact URL the row requests.
  private let libraryThumbnailPixelWidth: Int
  /// App composition must pass `ArtworkVariant.highFidelity(displaySize: 272, displayScale:
  /// scale).pixelWidth`: the detail hero (272 pt) and context preview (300 pt) quantize to this
  /// width. This UIKit-free actor must not re-derive it; a wrong value warms a key no surface
  /// requests.
  private let highFidelityPixelWidth: Int
  /// Podcast episode cards use a 56-point thumbnail rather than the canonical 44-point library
  /// row size. Podcast-only, so audiobooks and ebooks do not enlarge the thumbnail tier.
  private let podcastEpisodeThumbnailPixelWidth: Int
  /// The 140-point card rung, warmed for every item. The regular-width Library browse grid asks
  /// for it for every title, not just podcasts. App composition resolves the scale-specific
  /// 280/420px width.
  private let homeCardPixelWidth: Int
  private let artworkScope: ArtworkAccountScope
  let shapeStore: CoverShapeRecordStore
  /// Nil in a composition that does not fit detail covers to their shape; the detail tier is then
  /// keyed by `highFidelityPixelWidth` for every item.
  let shapes: CoverShapeMeasurement?
  var shapesLoaded = false
  private let isConstrainedOrCellular: @Sendable () -> Bool
  let now: @Sendable () -> Date
  private let randomUnit: @Sendable () -> Double

  var passSlot = CoalescedPassSlot<CoverCacheRunOutcome>()

  private enum ItemOutcome: Sendable {
    case fetched
    case alreadyPresent
    case failed
    case unavailable
    case cancelled
  }

  enum VariantOutcome: Sendable, Equatable {
    case fetched
    case alreadyPresent
    case failed
    case unavailable
    case cancelled
  }

  enum CacheVariant: Sendable {
    case libraryThumbnail
    case highFidelity
    case podcastEpisodeThumbnail
    case homeCard
  }

  private var suspended = false
  private var suspensionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

  private var currentProgress = CoverCacheProgress(
    processed: 0, newlyCovered: 0, total: 0, isRunning: false)
  private var progressBucket: Int?
  private var progressSubscribers: [UUID: AsyncStream<CoverCacheProgress>.Continuation] = [:]

  private var fetchBackoff: ABSApi.BackoffPolicy?
  private var nextFetchAllowedAt: Date?

  public init(
    database: AppDatabase,
    covers: any CoverCacheFilling,
    libraryThumbnailPixelWidth: Int,
    highFidelityPixelWidth: Int,
    podcastEpisodeThumbnailPixelWidth: Int,
    homeCardPixelWidth: Int,
    artworkScope: ArtworkAccountScope,
    shapes: CoverShapeMeasurement? = nil,
    isConstrainedOrCellular: @escaping @Sendable () -> Bool = { false },
    now: @escaping @Sendable () -> Date = Date.init,
    randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    accountDAO = AccountDAO(database: database)
    itemDAO = ItemDAO(database: database)
    self.covers = covers
    self.libraryThumbnailPixelWidth = libraryThumbnailPixelWidth
    self.highFidelityPixelWidth = highFidelityPixelWidth
    self.podcastEpisodeThumbnailPixelWidth = podcastEpisodeThumbnailPixelWidth
    self.homeCardPixelWidth = homeCardPixelWidth
    self.artworkScope = artworkScope
    shapeStore = CoverShapeRecordStore(database: database)
    self.shapes = shapes
    self.isConstrainedOrCellular = isConstrainedOrCellular
    self.now = now
    self.randomUnit = randomUnit
  }

  /// A new subscription to run progress. Each call registers its own continuation and replays the
  /// current value, so a screen that appears mid-pass shows the real figure at once.
  public var progress: AsyncStream<CoverCacheProgress> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<CoverCacheProgress>.makeStream()
    progressSubscribers[id] = continuation
    continuation.yield(currentProgress)
    continuation.onTermination = { [weak self] _ in
      Task { await self?.removeProgressSubscriber(id: id) }
    }
    return stream
  }

  /// Runs one complete pass without a network-condition gate. `topUp()` is the production caller
  /// and applies the Wi-Fi/constrained policy in front of it; `runAll()` is also the seam tests
  /// and maintenance use to exercise a pass regardless of the radio.
  public func runAll() async -> CoverCacheRunOutcome {
    let outcome = await runCoalescedPass(policy: .shareInFlight) {
      await self.performRun()
    }
    return outcome.value
  }

  /// Runs the complete pass on the automatic path: the injected network predicate must report an
  /// unconstrained, non-cellular path. This is the only production entry point, and the gate is
  /// what keeps account-wide work off cellular.
  public func topUp() async -> CoverCacheRunOutcome {
    guard isConstrainedOrCellular() == false else {
      return Self.zeroOutcome(finished: false)
    }
    return await runAll()
  }

  /// Cancels the in-flight pass. Any fetches that observe cancellation stop promptly; a cover
  /// client may still retain bytes whose transfer had already completed, as required by its
  /// sunk-transfer caching contract.
  public func cancel() {
    passSlot.flight?.task.cancel()
  }

  /// Pauses or resumes the current pass. App composition owns lifecycle policy and calls this for
  /// background/foreground transitions; the coordinator does not subscribe to AppLifecycle.
  public func setSuspended(_ suspended: Bool) {
    self.suspended = suspended
    guard suspended == false else { return }

    let waiters = suspensionWaiters.values
    suspensionWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  /// Measures the disposable cache itself, with no network fallback. An OS purge therefore lowers
  /// the count naturally and a later explicit pass can refill it. Cancellation stops the scan at
  /// the next item and returns the number observed so far against the known library total.
  public func census() async -> ItemDAO.MetadataCensus {
    guard let account = try? await accountDAO.fetchAsync(), let accountID = account.id else {
      return ItemDAO.MetadataCensus(covered: 0, total: 0)
    }
    guard
      let items = try? await itemDAO.serverItemKindsEligibleForArtworkAsync(accountId: accountID)
    else {
      return ItemDAO.MetadataCensus(covered: 0, total: 0)
    }

    await loadShapes()
    var covered = 0
    for item in items {
      guard Task.isCancelled == false else { break }
      let variants = variants(for: item)
      var itemCovered = true
      for variant in variants {
        if await covers.contains(key(for: item, variant: variant)) == false {
          itemCovered = false
        }
      }
      if itemCovered {
        covered += 1
      }
    }
    return ItemDAO.MetadataCensus(covered: covered, total: items.count)
  }

  private func performRun() async -> CoverCacheRunOutcome {
    guard let account = try? await accountDAO.fetchAsync(), let accountID = account.id else {
      return Self.zeroOutcome(finished: false)
    }
    guard
      let items = try? await itemDAO.serverItemKindsEligibleForArtworkAsync(accountId: accountID)
    else {
      return Self.zeroOutcome(finished: false)
    }

    await loadShapes()
    let total = items.count
    publishProgress(processed: 0, newlyCovered: 0, total: total, isRunning: true, force: true)
    guard total > 0 else {
      publishProgress(processed: 0, newlyCovered: 0, total: 0, isRunning: false, force: true)
      return Self.zeroOutcome(finished: true)
    }

    var nextIndex = 0
    var processed = 0
    var newlyCovered = 0
    var fetched = 0
    var alreadyPresent = 0
    var failed = 0
    var unavailable = 0
    var wasCancelled = false

    await withTaskGroup(of: ItemOutcome.self) { group in
      for _ in 0..<min(2, items.count) {
        guard let item = Self.nextItem(from: items, nextIndex: &nextIndex) else { break }
        group.addTask { [weak self] in
          guard let self else { return .cancelled }
          return await self.process(item: item, accountID: accountID)
        }
      }

      while let itemOutcome = await group.next() {
        switch itemOutcome {
        case .fetched:
          fetched += 1
          newlyCovered += 1
        case .alreadyPresent:
          alreadyPresent += 1
        case .failed:
          failed += 1
        case .unavailable:
          unavailable += 1
        case .cancelled:
          wasCancelled = true
          group.cancelAll()
        }

        if case .cancelled = itemOutcome {
          break
        }

        if suspended {
          do {
            try await waitUntilResumed()
          } catch {
            wasCancelled = true
            group.cancelAll()
            break
          }
        }

        processed += 1
        publishProgress(
          processed: processed, newlyCovered: newlyCovered, total: total, isRunning: true)

        guard Task.isCancelled == false else {
          wasCancelled = true
          group.cancelAll()
          break
        }
        guard let item = Self.nextItem(from: items, nextIndex: &nextIndex) else { continue }
        group.addTask { [weak self] in
          guard let self else { return .cancelled }
          return await self.process(item: item, accountID: accountID)
        }
      }

      if Task.isCancelled {
        wasCancelled = true
        group.cancelAll()
      }
    }

    let finished = wasCancelled == false && Task.isCancelled == false && processed == total
    if finished {
      await prune(accountID: accountID, eligible: items)
      // Every cover the pass wants is in the store now, so the old cache has nothing left to give.
      if failed == 0 { await covers.retireLegacyCache() }
    }
    publishProgress(
      processed: processed, newlyCovered: newlyCovered, total: total, isRunning: false, force: true)
    return CoverCacheRunOutcome(
      fetched: fetched, alreadyPresent: alreadyPresent, failed: failed, unavailable: unavailable,
      finished: finished)
  }

  private func process(item: ItemDAO.ServerItemKind, accountID: Int64) async -> ItemOutcome {
    var fetched = false
    var failed = false

    for variant in variants(for: item) {
      let variantOutcome = await process(
        item: item, variant: variant, accountID: accountID)
      switch variantOutcome {
      case .fetched:
        fetched = true
      case .alreadyPresent:
        break
      case .failed:
        failed = true
      case .unavailable:
        return .unavailable
      case .cancelled:
        return .cancelled
      }
    }

    if failed { return .failed }
    return fetched ? .fetched : .alreadyPresent
  }

  private func process(
    item: ItemDAO.ServerItemKind, variant: CacheVariant, accountID: Int64
  ) async -> VariantOutcome {
    if variant == .highFidelity, let shapes, needsMeasurement(item, shapes: shapes) {
      return await measureAndFetchDetail(item: item, shapes: shapes, accountID: accountID)
    }
    return await ensure(key(for: item, variant: variant), item: item, accountID: accountID)
  }

  /// Makes one cover present: a presence check, then a fetch on a miss.
  func ensure(
    _ key: ArtworkKey, item: ItemDAO.ServerItemKind, accountID: Int64
  ) async -> VariantOutcome {
    do {
      try Task.checkCancellation()
      try await waitUntilResumed()
      try Task.checkCancellation()

      if await covers.contains(key) {
        return .alreadyPresent
      }
      try Task.checkCancellation()
      try await waitForBackoff()
      try Task.checkCancellation()
      _ = try await covers.fetch(key)
      resetBackoff()
      return .fetched
    } catch is CancellationError {
      return .cancelled
    } catch APIError.notFound {
      // Availability is width-independent: a 404 means the item has no server bytes for any
      // variant. Persist that so later censuses and passes skip the placeholder.
      try? await itemDAO.setHasServerArtworkAsync(
        false, accountId: accountID, serverItemId: item.serverItemId)
      return .unavailable
    } catch {
      guard Task.isCancelled == false else { return .cancelled }
      scheduleBackoff()
      return .failed
    }
  }

  private func waitUntilResumed() async throws {
    guard suspended else { return }
    try Task.checkCancellation()
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else if suspended == false {
          continuation.resume()
        } else {
          suspensionWaiters[id] = continuation
        }
      }
    } onCancel: {
      Task { await self.cancelSuspensionWaiter(id: id) }
    }
  }

  private func cancelSuspensionWaiter(id: UUID) {
    guard let waiter = suspensionWaiters.removeValue(forKey: id) else { return }
    waiter.resume(throwing: CancellationError())
  }

  private func waitForBackoff() async throws {
    guard let nextFetchAllowedAt else { return }
    let remaining = nextFetchAllowedAt.timeIntervalSince(now())
    guard remaining > 0 else { return }
    try await Task.sleep(for: .seconds(remaining))
    try Task.checkCancellation()
  }

  private func scheduleBackoff() {
    let failureDate = now()
    var policy = fetchBackoff ?? ABSApi.BackoffPolicy()
    let delay = policy.nextDelay(now: failureDate, randomUnit: randomUnit())
    fetchBackoff = policy
    nextFetchAllowedAt = failureDate.addingTimeInterval(delay)
  }

  private func resetBackoff() {
    fetchBackoff = nil
    nextFetchAllowedAt = nil
  }

  func key(for item: ItemDAO.ServerItemKind, variant: CacheVariant) -> ArtworkKey {
    let artworkVariant: ArtworkVariant
    switch variant {
    case .libraryThumbnail:
      artworkVariant = .libraryThumbnail(pixelWidth: libraryThumbnailPixelWidth)
    case .highFidelity:
      artworkVariant = detailVariant(for: item)
    case .podcastEpisodeThumbnail:
      artworkVariant = .libraryThumbnail(pixelWidth: podcastEpisodeThumbnailPixelWidth)
    case .homeCard:
      artworkVariant = .homeCard(pixelWidth: homeCardPixelWidth)
    }

    return key(for: item, artworkVariant: artworkVariant)
  }

  func key(for item: ItemDAO.ServerItemKind, artworkVariant: ArtworkVariant) -> ArtworkKey {
    ArtworkKey(
      accountScope: artworkScope,
      itemID: item.serverItemId,
      variant: artworkVariant,
      revision: ArtworkRevision(serverUpdatedAt: item.serverUpdatedAt))
  }

  /// The detail key the views resolve for this item: fitted to its shape once that is measured,
  /// and today's width until then.
  private func detailVariant(for item: ItemDAO.ServerItemKind) -> ArtworkVariant {
    guard let shapes else { return .highFidelity(pixelWidth: highFidelityPixelWidth) }
    return shapes.sizing.variant(
      for: shapes.index.shape(
        itemID: item.serverItemId,
        revision: ArtworkRevision(serverUpdatedAt: item.serverUpdatedAt)))
  }

  func variants(for item: ItemDAO.ServerItemKind) -> [CacheVariant] {
    // The card rung is unconditional: the regular-width Library grid draws it for every title.
    // The episode thumbnail stays podcast-only (no book surface requests that 56-point size).
    // The card comes before the detail cover because the detail width is measured from it.
    var variants: [CacheVariant] = [.homeCard, .libraryThumbnail, .highFidelity]
    if item.mediaKind == ItemMediaCategory.podcast.rawValue {
      variants.append(.podcastEpisodeThumbnail)
    }
    return variants
  }

  private func publishProgress(
    processed: Int, newlyCovered: Int, total: Int, isRunning: Bool, force: Bool = false
  ) {
    // The first item is emitted so a cold cache visibly moves. After that the UI renders whole
    // percentage points, so at most one running update per point, not one main-actor
    // invalidation per item. Start and finish always emit because `isRunning` is rendered.
    let bucket = total == 0 ? 0 : min(100, max(0, processed * 100 / total))
    guard
      force || currentProgress.isRunning != isRunning || currentProgress.total != total
        || processed == 1 || progressBucket != bucket
    else { return }

    currentProgress = CoverCacheProgress(
      processed: processed, newlyCovered: newlyCovered, total: total, isRunning: isRunning)
    progressBucket = bucket
    for continuation in progressSubscribers.values {
      continuation.yield(currentProgress)
    }
  }

  private func removeProgressSubscriber(id: UUID) {
    progressSubscribers.removeValue(forKey: id)
  }

  private static func nextItem(
    from items: [ItemDAO.ServerItemKind], nextIndex: inout Int
  ) -> ItemDAO.ServerItemKind? {
    guard nextIndex < items.count else { return nil }
    defer { nextIndex += 1 }
    return items[nextIndex]
  }

  private static func zeroOutcome(finished: Bool) -> CoverCacheRunOutcome {
    CoverCacheRunOutcome(
      fetched: 0, alreadyPresent: 0, failed: 0, unavailable: 0, finished: finished)
  }
}

extension CoverCacheAllCoordinator: ArtworkCachePassCancelling {}
