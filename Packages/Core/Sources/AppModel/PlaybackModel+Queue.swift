import CoreSupport
import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine

extension PlaybackModel {

  /// Swaps Now Playing with an Up Next row: the row starts as `start(queueItem:)` would, and once
  /// it has started, the title it displaced goes to the front of Up Next, so it resumes when the
  /// row finishes. A failed start returns nothing. With nothing playing, or the row's own title
  /// playing, this is a plain start.
  ///
  /// Like any Up Next start, it ends an active smart-list run (ADR 0016), so the displaced title
  /// is what plays next.
  public func swap(toQueueItem queueItem: ListeningQueueItem) async {
    let displaced = nowPlayingIdentity.flatMap { $0 == queueItem.identity ? nil : $0 }
    await start(
      itemID: queueItem.identity.itemID, episodeID: queueItem.identity.episodeID,
      fromStart: false, origin: .requested, forceFreshSession: false, expectedGeneration: nil,
      extent: QueueStartExtent(queueItem), displacing: displaced)
  }

  /// Skips the displayed item named by `itemID` by `delta` seconds, clamped at zero. The
  /// already-active item is skipped synchronously against `currentTime`, with no `await` before the
  /// `.seek` intent (like `play(itemID:)`'s fast path), bypassing the coalescer. A not-yet-active
  /// item must first `start`; see `retainedSkipPreparationTask` for coalescing taps meanwhile.
  ///
  /// The in-flight-preparation check runs before the already-active check: `start` sets
  /// `activeItemID` well before `startSession` resolves, so a tap during our own coalesced
  /// preparation would look active and seek at once instead of folding into the accumulated offset.
  public func skip(itemID: String, by delta: Double) async {
    guard let item = displayedItem, item.serverItemId == itemID else { return }
    await skip(itemID: itemID, episodeID: item.episodeID, by: delta)
  }

  /// Bounded relative movement for surfaces that are a scrub rather than a skip, such as the
  /// scrubber's VoiceOver adjustable action. It can never finish the item: an assistive nudge along
  /// a slider must not consume an Up Next row. The Skip Forward control remains available and does.
  public func adjust(itemID: String, episodeID: String?, by delta: Double) async {
    if activeItemID == itemID, activeEpisodeID == episodeID,
      loadedItemID == itemID, loadedEpisodeID == episodeID
    {
      seek(itemID: itemID, toGlobalOffset: max(0, currentTime + delta))
      return
    }
    await skip(itemID: itemID, episodeID: episodeID, by: delta)
  }

  public func skip(itemID: String, episodeID: String?, by delta: Double) async {
    let targetEpisodeID = episodeID
    if let inFlight = retainedSkipPreparationTask,
      retainedSkipPreparationItemID == itemID,
      retainedSkipPreparationEpisodeID == targetEpisodeID
    {
      pendingRetainedSkipOffset += delta
      await inFlight.value
      return
    }

    if activeItemID == itemID, activeEpisodeID == targetEpisodeID,
      loadedItemID == itemID, loadedEpisodeID == targetEpisodeID
    {
      // Relative, not an absolute seek to `currentTime + delta`: only the skip intent is allowed to
      // run past the end and finish the item, and PlayerCore resolves the target from the position
      // it actually holds rather than this model's mirrored copy of it.
      skipLoaded(itemID: itemID, episodeID: targetEpisodeID, by: delta)
      return
    }

    // `activeItemID` changes before preparation finishes, while `loadedItemID` still identifies
    // the previous player item. Controls are disabled in this state; this guard also makes the
    // model boundary safe if an already-enqueued tap arrives anyway.
    if activeItemID == itemID, loadedItemID != itemID { return }
    guard let item = displayedItem, item.serverItemId == itemID,
      item.episodeID == targetEpisodeID
    else { return }

    let savedPosition = displayedItemPositionSeconds
    pendingRetainedSkipOffset = delta
    retainedSkipPreparationItemID = itemID
    retainedSkipPreparationEpisodeID = targetEpisodeID
    let task = Task { [weak self] () -> Void in
      guard let self else { return }
      await self.performRetainedSkipPreparation(
        itemID: itemID, episodeID: item.episodeID, savedPosition: savedPosition)
    }
    retainedSkipPreparationTask = task
    await task.value
  }

  /// Sole owner of the in-flight `start` for a retained-item skip, and applies the accumulated
  /// offset once. `start`'s failure contract already records the failure report
  /// (`startFailureMessage`) and leaves `activeItemID`/`displayedItem` untouched, so on failure
  /// this only skips the seek.
  private func performRetainedSkipPreparation(
    itemID: String, episodeID: String?, savedPosition: Double
  ) async {
    await start(itemID: itemID, episodeID: episodeID)
    defer {
      retainedSkipPreparationTask = nil
      retainedSkipPreparationItemID = nil
      retainedSkipPreparationEpisodeID = nil
      pendingRetainedSkipOffset = 0
    }
    guard loadedItemID == itemID else { return }
    seek(itemID: itemID, toGlobalOffset: max(0, savedPosition + pendingRetainedSkipOffset))
  }

  /// Runs completion policy without retaining the model across SyncEngine or queue awaits. The
  /// bridge owns the durable task, so an async instance-method callback would otherwise form
  /// `model → bridge → task → model` while a non-cooperative close was suspended.
  internal static func driveCompletion(
    model: @escaping @MainActor () -> PlaybackModel?,
    sync: any PlaybackSyncing,
    listeningQueue: any ListeningQueueStoring,
    continuation: any PlaybackContinuationSource = NoOpPlaybackContinuationSource(),
    envelope: PlaybackEventBridge.Envelope,
    shouldAdvance: Bool
  ) async {
    let generation = envelope.modelGeneration
    guard
      let identity = ListeningIdentity.resolving(
        itemID: envelope.event.itemId, episodeID: envelope.event.episodeID)
    else { return }
    guard envelope.event.phase == .ended,
      model()?.beginCompletion(envelope) == true
    else { return }

    await sync.notifyImmediateSyncTrigger(.closing)
    guard model()?.isCurrent(envelope) == true else { return }
    do {
      try await sync.stopSession()
    } catch {
      model()?.applyCompletionFailure(envelope: envelope, identity: identity)
      return
    }
    guard model()?.finishCompletedSession(envelope) == true else { return }

    // A completion that does not continue (a sleep timer, `endBehavior == .stop`) still closes
    // the finished session. Nothing plays, but a live smart-list or Up Next continuation is
    // prepared paused, so the finished title leaves the player with its next row ready.
    guard shouldAdvance else {
      await model()?.prepareContinuationPaused(
        after: identity, clearing: .wholeBookRow, generation: generation)
      return
    }

    // The completed identity's own row goes first. An identity can be both Now Playing and
    // queued, and peeking before removing it would return the item that just finished.
    guard model()?.ownsGeneration(generation) == true else { return }
    do {
      // Narrowed: only a whole-book row goes. The book's queued chapter rows are the listener's
      // planned stories and play next.
      try await listeningQueue.acknowledgeStarted(identity: identity, rowID: nil)
    } catch {
      model()?.applyQueueAdvanceFailure(generation: generation, identity: identity)
      return
    }
    guard model()?.ownsGeneration(generation) == true else { return }

    // An active smart list plays before Up Next (ADR 0016). Its success or failure never falls
    // through to the queue; only a drained list does.
    switch await driveListAdvance(
      model: model, continuation: continuation, generation: generation, finished: identity)
    {
    case .advanced, .stopped: return
    case .noRun, .drained: break
    }

    // Peek the first live row (tombstones skipped, never deleted) and start it through this same
    // model. `start` acknowledges it only once preparation has succeeded, so a failed start
    // leaves the row where it was.
    let next = await listeningQueue.peekNextLive()
    guard model()?.ownsGeneration(generation) == true else { return }
    guard let next else { return }
    await model()?.start(queueItem: next, origin: .queueAdvance)
  }

  /// A queued chapter reached its end: the player has paused there, mid-book. The book is not
  /// finished and its session stays open, so nothing closes; the next Up Next row starts, and with
  /// none the book stays loaded and paused at the chapter's end.
  internal static func driveSegmentAdvance(
    model: @escaping @MainActor () -> PlaybackModel?,
    listeningQueue: any ListeningQueueStoring,
    envelope: PlaybackEventBridge.Envelope
  ) async {
    let generation = envelope.modelGeneration
    guard envelope.event.segmentEnd == .reached, envelope.event.phase != .ended,
      model()?.isCurrent(envelope) == true
    else { return }
    let next = await listeningQueue.peekNextLive()
    guard model()?.ownsGeneration(generation) == true, let next else { return }
    await model()?.start(queueItem: next, origin: .queueAdvance)
  }

  /// After the active title was finished without continuing playback: prepares the next
  /// smart-list or Up Next continuation paused, or does nothing, leaving presence to clear.
  ///
  /// `generation` is the caller's `playbackGeneration`, captured once its `stop()` has fully
  /// returned. A Play tapped during the finish write must win, so this acts only while it still
  /// owns that generation and nothing is active, and it passes the generation into `start`.
  ///
  /// A failure inside `start` is `start`'s own (recoverable, with the new row active and its
  /// banner visible). A failure before `start` leaves presence `nil`, where no surface exists, so
  /// it is logged and nothing is presented.
  internal func prepareContinuationPaused(
    after finished: ListeningIdentity, clearing: FinishedRowClearing, generation: Int
  ) async {
    guard ownsGeneration(generation), activeItemID == nil else { return }

    // The finished title's rows go before the peek, so it cannot return the title that just
    // finished. A book that played to its end keeps its queued chapter rows; one the
    // listener marked finished loses every row.
    do {
      switch clearing {
      case .wholeBookRow: try await listeningQueue.acknowledgeStarted(identity: finished, rowID: nil)
      case .everyRow: try await listeningQueue.remove(identity: finished)
      }
    } catch {
      Self.log.error(
        "Continuation preparation could not clear the finished title's row: \(String(describing: type(of: error)), privacy: .public)"
      )
      return
    }
    guard ownsGeneration(generation), activeItemID == nil else { return }

    // An active smart list comes first (ADR 0016). Every start bumps the generation, so the
    // generation checks after this call cover a Play tapped during any of its awaits.
    switch await Self.driveListAdvance(
      model: { [weak self] in self }, continuation: continuation, generation: generation,
      finished: finished, playAfterStart: false, reportsFailure: false)
    {
    case .advanced, .stopped: return
    case .noRun, .drained: break
    }

    guard ownsGeneration(generation), activeItemID == nil else { return }
    guard let next = await listeningQueue.peekNextLive() else { return }
    guard ownsGeneration(generation), activeItemID == nil else { return }
    await start(
      itemID: next.identity.itemID, episodeID: next.identity.episodeID, fromStart: false,
      origin: .queueAdvance, forceFreshSession: false, expectedGeneration: generation,
      playAfterStart: false,
      extent: QueueStartExtent(next))
  }

  /// Which of a finished title's Up Next rows go before the next continuation is peeked.
  internal enum FinishedRowClearing: Sendable {
    /// The title played to its end: its whole-book or episode row, as a start consumes it.
    case wholeBookRow
    /// The listener marked the title finished: every row, its queued chapters too.
    case everyRow
  }

  /// What a start from an Up Next row plays: the whole title, or one chapter of a book. A chapter
  /// carries its row, the one thing that names it among the book's other chapter rows: a chapter
  /// start that consumed nothing would be peeked and replayed forever.
  internal enum QueueStartExtent: Sendable, Equatable {
    case whole
    case chapter(ListeningQueueRowChapter)

    init(_ row: ListeningQueueItem) {
      self = row.rowChapter.map(QueueStartExtent.chapter) ?? .whole
    }

    var chapter: ListeningQueueChapter? {
      if case .chapter(let queued) = self { queued.chapter } else { nil }
    }

    /// The row a start consumes beside the title's whole-book row.
    var rowID: Int64? {
      if case .chapter(let queued) = self { queued.rowID } else { nil }
    }
  }

  private func beginCompletion(_ envelope: PlaybackEventBridge.Envelope) -> Bool {
    let generation = envelope.modelGeneration
    guard isCurrent(envelope), completedGeneration != generation else { return false }
    completedGeneration = generation
    return true
  }

  private func applyCompletionFailure(
    envelope: PlaybackEventBridge.Envelope, identity: ListeningIdentity
  ) {
    guard isCurrent(envelope) else { return }
    setQueueAdvanceFailure(identity: identity, origin: .queueAdvance)
  }

  internal func setQueueAdvanceFailure(
    identity: ListeningIdentity, origin: PlaybackStartFailure.Origin
  ) {
    setPhase(.recoverableError)
    failedStartIdentity = (itemID: identity.itemID, episodeID: identity.episodeID)
    failedStartExtent = nil
    setStartFailure(
      PlaybackStartFailure(message: PlaybackCopy.genericStartFailure, origin: origin))
  }

  private func finishCompletedSession(_ envelope: PlaybackEventBridge.Envelope) -> Bool {
    guard isCurrent(envelope) else { return false }
    setActive(itemID: nil, episodeID: nil)
    setLoaded(itemID: nil, episodeID: nil, isStreaming: false)
    setPhase(.idle)
    return true
  }

  private func applyQueueAdvanceFailure(generation: Int, identity: ListeningIdentity) {
    guard ownsGeneration(generation) else { return }
    setQueueAdvanceFailure(identity: identity, origin: .queueAdvance)
  }

  /// `start` writes the retained bookmark when preparation succeeds, so on relaunch its first
  /// projection can name an identity whose queue row was never acknowledged before the process
  /// ended. One idempotent, position-independent `acknowledgeStarted` closes that window. It never
  /// starts playback, and it skips a finished bookmark: that title is not presented, so removing
  /// its Up Next row would silently lose a row while nothing is on screen.
  internal func reconcileQueueWithRetainedIdentityIfNeeded(_ bookmark: PlaybackBookmark?) async {
    guard hasReconciledRetainedIdentity == false, let bookmark, bookmark.isFinished == false
    else { return }
    hasReconciledRetainedIdentity = true
    guard
      let identity = ListeningIdentity.resolving(itemID: bookmark.serverItemId, episodeID: bookmark.episodeID)
    else { return }
    try? await listeningQueue.acknowledgeStarted(identity: identity, rowID: nil)
  }
}
