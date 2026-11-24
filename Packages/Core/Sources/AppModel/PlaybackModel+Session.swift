import CoreSupport
import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine

extension PlaybackModel {

  // MARK: - Intents

  /// Starts a new item, or resumes the one already active (`PlaybackSyncing.startSession`'s own
  /// idempotent-start/resume/switch contract). A requested failed start leaves no phantom
  /// mini-player; an automatic queue-advance failure keeps its requested identity visible so the
  /// player can explain and retry it. A no-op once `logout()` has begun.
  ///
  /// `origin` records who was waiting, so a refusal surfaces differently for a tapped play than for
  /// the automatic continuation after a title finishes; it defaults to the user's own request.
  /// `fromStart` bypasses the saved resume position for replaying a finished title.
  ///
  /// `run` is passed only by a smart list's own Play, rows and cards: `.begin` starts the list's
  /// run once this start succeeds. Every other `.requested` start ends an active run unless it is
  /// the run's anchor episode (ADR 0016).
  public func start(
    itemID: String, episodeID: String? = nil,
    fromStart: Bool = false,
    origin: PlaybackStartFailure.Origin = .requested,
    run: RunIntent? = nil
  ) async {
    await start(
      itemID: itemID, episodeID: episodeID, fromStart: fromStart, origin: origin,
      forceFreshSession: false, expectedGeneration: nil, run: run)
  }

  /// Starts an Up Next row. A chapter row starts at its chapter and stops at the chapter's end,
  /// whatever position the book had saved; a whole-book or episode row resumes as any start does.
  /// There is no row-less form: a chapter row is named by its id among the book's other chapter
  /// rows, and the start consumes exactly that row.
  public func start(
    queueItem: ListeningQueueItem, origin: PlaybackStartFailure.Origin = .requested
  ) async {
    await start(
      itemID: queueItem.identity.itemID, episodeID: queueItem.identity.episodeID,
      fromStart: false, origin: origin, forceFreshSession: false, expectedGeneration: nil,
      extent: QueueStartExtent(queueItem))
  }

  /// `start(queueItem:origin:)` for a surface that holds the row's identity and chapter apart.
  public func start(
    identity: ListeningIdentity, queuedChapter: ListeningQueueRowChapter,
    origin: PlaybackStartFailure.Origin = .requested
  ) async {
    await start(
      itemID: identity.itemID, episodeID: identity.episodeID, fromStart: false, origin: origin,
      forceFreshSession: false, expectedGeneration: nil, extent: .chapter(queuedChapter))
  }

  /// `start(itemID:episodeID:)` for a caller that must act only on a start that happened, such as
  /// a collection's Play, which queues the rest only after its first entry began. True when the
  /// requested identity is the active one with no start failure once the start returns.
  public func startReportingSuccess(
    itemID: String, episodeID: String?, fromStart: Bool = false, run: RunIntent? = nil
  ) async -> Bool {
    await start(itemID: itemID, episodeID: episodeID, fromStart: fromStart, run: run)
    return startFailure == nil && activeItemID == itemID && activeEpisodeID == episodeID
  }

  internal func start(
    itemID: String, episodeID: String?, fromStart: Bool, origin: PlaybackStartFailure.Origin,
    forceFreshSession: Bool, expectedGeneration: Int?, playAfterStart: Bool = true,
    initialPosition: Double? = nil, run: RunIntent? = nil, extent: QueueStartExtent? = nil,
    displacing displaced: ListeningIdentity? = nil
  ) async {
    guard isQuiescedForLogout == false else { return }
    if let expectedGeneration, playbackGeneration != expectedGeneration { return }
    // Anything this process starts itself supersedes the relaunch reconciliation below: from here
    // on, a row is consumed by the start that actually happened, never by the retained projection.
    hasReconciledRetainedIdentity = true
    await recoveryTask?.value
    // Recovery is awaited, so logout can begin while this caller is parked at the gate. Its
    // preflight is permanent for this model; rechecking here stops that old caller reopening
    // playback after quiescence has completed.
    guard startIsStillWanted(expectedGeneration: expectedGeneration) else { return }
    await endRunForStartIfNeeded(itemID: itemID, episodeID: episodeID, origin: origin, run: run)
    guard startIsStillWanted(expectedGeneration: expectedGeneration) else { return }

    guard
      let authorization = await authorizedStart(
        itemID: itemID, episodeID: episodeID, fromStart: fromStart,
        initialPosition: initialPosition, origin: origin, expectedGeneration: expectedGeneration)
    else { return }

    discardFreshSessionRequest(itemID: itemID, episodeID: episodeID)

    let isActiveIdentity = activeItemID == itemID && activeEpisodeID == episodeID
    let shouldRetireActiveSession =
      isActiveIdentity && isStreamingSource && Self.isDeadSessionPhase(phase)
    let shouldStartFreshLocalSession =
      freshLocalSessionOnNextPlay?.itemID == itemID
      && freshLocalSessionOnNextPlay?.episodeID == episodeID

    setStartFailure(nil)
    failedStartIdentity = nil
    failedStartRun = nil
    failedStartExtent = nil
    if let extent, forceFreshSession == false, shouldStartFreshLocalSession == false,
      playAfterStart, isActiveIdentity, Self.isResumable(phase),
      loadedItemID == itemID, loadedEpisodeID == episodeID
    {
      await startQueueRowInLoadedItem(itemID: itemID, episodeID: episodeID, extent: extent)
      return
    }
    if forceFreshSession == false, shouldStartFreshLocalSession == false,
      playAfterStart,
      isActiveIdentity, Self.isResumable(phase),
      fromStart == false || (loadedItemID == itemID && loadedEpisodeID == episodeID)
    {
      await resumeActiveSession(
        itemID: itemID, episodeID: episodeID, fromStart: fromStart, origin: origin, run: run,
        peerPosition: authorization.peerPosition)
      return
    }

    await beginFreshSession(
      itemID: itemID, episodeID: episodeID, fromStart: fromStart, origin: origin,
      retireActiveSession: shouldRetireActiveSession, playAfterStart: playAfterStart,
      initialPosition: authorization.initialPosition, run: run, extent: extent,
      displacing: displaced)
  }

  /// The gate a start crosses again after each await: logout and a displaced generation both stop
  /// it, and a cancelled task stops it too.
  private func startIsStillWanted(expectedGeneration: Int?) -> Bool {
    guard isQuiescedForLogout == false, Task.isCancelled == false else { return false }
    if let expectedGeneration, playbackGeneration != expectedGeneration { return false }
    return true
  }

  /// The start's authorized position, or nil when it was refused, in which case the failure is
  /// already installed. `peerPosition` is the peer's position when it supplied one.
  private func authorizedStart(
    itemID: String, episodeID: String?, fromStart: Bool, initialPosition: Double?,
    origin: PlaybackStartFailure.Origin, expectedGeneration: Int?
  ) async -> (initialPosition: Double?, peerPosition: Double?)? {
    guard let authorizePlaybackStart else { return (initialPosition, nil) }
    let authorization = await authorizePlaybackStart(itemID, episodeID)
    guard !isQuiescedForLogout, !Task.isCancelled else { return nil }
    if let expectedGeneration, playbackGeneration != expectedGeneration { return nil }
    switch authorization {
    case .allowed(let position):
      guard !fromStart, let position, position.isFinite, position >= 0 else {
        return (initialPosition, nil)
      }
      return (position, position)
    case .denied(let message):
      setStartFailure(PlaybackStartFailure(message: message, origin: origin))
      return nil
    }
  }

  /// Drops a fresh-session request for another identity: only the identity it named gets it.
  private func discardFreshSessionRequest(itemID: String, episodeID: String?) {
    if let pending = freshLocalSessionOnNextPlay,
      pending.itemID != itemID || pending.episodeID != episodeID
    {
      freshLocalSessionOnNextPlay = nil
    }
  }

  /// Resumes the title already loaded and resumable: the play intent reaches the cadence, the
  /// player seeks where the request asks, and the run records the start.
  private func resumeActiveSession(
    itemID: String, episodeID: String?, fromStart: Bool, origin: PlaybackStartFailure.Origin,
    run: RunIntent?, peerPosition: Double?
  ) async {
    // The play intent must reach the cadence before a backgrounding can read a stale closable
    // phase (a bedtime resume-then-lock could close the fresh session one tick in). `.playing`
    // is exempt: its cadence deadline is live, and `forward` reports phase changes only, so
    // nothing would restart a deadline an eager `.buffering` cancels.
    switch phase {
    case .playing: break
    default: await sync.notifyPlaybackPhase(.buffering)
    }
    if fromStart {
      seek(itemID: itemID, toGlobalOffset: 0)
    } else if let peerPosition, abs(player.state.globalPosition - peerPosition) > 1 {
      // A peer that listened further (or elsewhere) hands its position over; the loaded title
      // must not resume from its own stale one.
      seek(itemID: itemID, toGlobalOffset: peerPosition)
    }
    player.send(.play)
    await recordRunStart(
      itemID: itemID, episodeID: episodeID, origin: origin, run: run,
      generation: playbackGeneration)
  }

  /// Opens a new generation-owned session behind the start operation tail.
  private func beginFreshSession(
    itemID: String, episodeID: String?, fromStart: Bool, origin: PlaybackStartFailure.Origin,
    retireActiveSession: Bool, playAfterStart: Bool, initialPosition: Double?, run: RunIntent?,
    extent: QueueStartExtent?, displacing displaced: ListeningIdentity?
  ) async {
    playbackGeneration += 1
    let requestedGeneration = playbackGeneration
    setActive(itemID: itemID, episodeID: episodeID)
    setPhase(.preparing)
    // Current PlaybackModel reports `.buffering` before `startSession`. Announce the requested item
    // first so a source router sends that pre-start cadence to the incoming origin, after the
    // generation bump so a suspended announcement cannot let a stale retry claim this start.
    sync.willStartPlayback(itemID: itemID)
    await sync.notifyPlaybackPhase(.buffering)

    let previousOperation = startOperationTail
    let operation = Task { [weak self] in
      await previousOperation?.value
      guard let self else { return }
      await self.performStart(
        itemID: itemID, episodeID: episodeID, generation: requestedGeneration, fromStart: fromStart,
        origin: origin, retireActiveSession: retireActiveSession,
        playAfterStart: playAfterStart, initialPosition: initialPosition, run: run,
        extent: extent, displacing: displaced)
    }
    startOperationTail = operation
    await withTaskCancellationHandler {
      await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  /// Performs the durable half of one generation-owned `start`. Operations run strictly in the
  /// order their public requests were accepted, while generation checks decide which operation
  /// may still mutate presentation state. A prepared session belonging to a displaced generation
  /// is closed here, before the operation tail admits its successor.
  private func performStart(
    itemID: String, episodeID: String?, generation: Int, fromStart: Bool,
    origin: PlaybackStartFailure.Origin,
    retireActiveSession: Bool, playAfterStart: Bool, initialPosition: Double?, run: RunIntent?,
    extent: QueueStartExtent?, displacing displaced: ListeningIdentity?
  ) async {
    guard ownsGeneration(generation) else { return }
    guard Task.isCancelled == false else {
      resetStartIfOwned(
        generation: generation, itemID: itemID, episodeID: episodeID, origin: origin, run: run,
        extent: extent)
      return
    }

    guard await retireSessionIfNeeded(retireActiveSession, generation: generation) else { return }
    guard
      let prepared = await openSession(
        itemID: itemID, episodeID: episodeID, generation: generation, origin: origin, run: run,
        extent: extent)
    else { return }
    guard
      let item = await playerItem(
        itemID: itemID, episodeID: episodeID, generation: generation, prepared: prepared,
        origin: origin, run: run, extent: extent)
    else { return }
    guard ownsGeneration(generation) else {
      // The session is already durably open, but its request lost ownership while awaiting
      // preparation. The successor is still parked on `startOperationTail`, so this stop can only
      // target the displaced session, never the one about to replace it.
      try? await sync.stopSession()
      return
    }
    guard
      await loadPreparedSession(
        prepared, item: item, itemID: itemID, episodeID: episodeID, generation: generation,
        fromStart: fromStart, playAfterStart: playAfterStart, initialPosition: initialPosition,
        extent: extent)
    else { return }

    seekPendingStart(itemID: itemID, episodeID: episodeID, generation: generation)
    await recordStartCompletion(
      itemID: itemID, episodeID: episodeID, generation: generation, origin: origin, run: run,
      extent: extent, displacing: displaced)
  }

  /// Retires a stalled or buffering stream's cached preparation before asking for the same
  /// identity again, so `startSession` cannot hand the dead resource back as an in-place resume.
  private func retireSessionIfNeeded(_ retire: Bool, generation: Int) async -> Bool {
    guard retire else { return true }
    try? await sync.stopSession()
    return ownsGeneration(generation) && Task.isCancelled == false
  }

  /// Opens the durable session, or installs the start's failure and answers nil.
  private func openSession(
    itemID: String, episodeID: String?, generation: Int, origin: PlaybackStartFailure.Origin,
    run: RunIntent?, extent: QueueStartExtent?
  ) async -> PreparedPlayback? {
    do {
      return try await sync.startSession(itemID: itemID, episodeID: episodeID)
    } catch {
      if ownsGeneration(generation) {
        await sync.notifyPlaybackPhase(.idle)
      }
      resetStartIfOwned(
        generation: generation, itemID: itemID, episodeID: episodeID, origin: origin, run: run,
        extent: extent,
        failureMessage: Task.isCancelled ? nil : PlaybackCopy.startFailureMessage(for: error))
      return nil
    }
  }

  /// The player item for an opened session, closing it and installing the failure when the task was
  /// cancelled meanwhile or the manifest fails PlayerCore's timeline validation.
  private func playerItem(
    itemID: String, episodeID: String?, generation: Int, prepared: PreparedPlayback,
    origin: PlaybackStartFailure.Origin, run: RunIntent?, extent: QueueStartExtent?
  ) async -> PlayerItem? {
    // The session is already durably open, server- and local-side. The driving task may have been
    // cancelled while `startSession` was in flight, or the returned manifest may fail
    // PlayerCore's stricter timeline validation. Either way the session must be closed here, or it
    // is orphaned until the next launch's recovery sweep.
    guard Task.isCancelled == false,
      let item = try? Self.makePlayerItem(itemID: itemID, prepared: prepared)
    else {
      let wasCancelled = Task.isCancelled
      if ownsGeneration(generation) {
        await sync.notifyPlaybackPhase(.idle)
      }
      try? await sync.stopSession()
      resetStartIfOwned(
        generation: generation, itemID: itemID, episodeID: episodeID, origin: origin, run: run,
        extent: extent, failureMessage: wasCancelled ? nil : PlaybackCopy.genericStartFailure)
      return nil
    }
    return item
  }

  /// Hands the opened session to PlayerCore: the trim map, the resolved rate, the start position
  /// and the presentation a load publishes. False when ownership was lost and the session closed.
  private func loadPreparedSession(
    _ prepared: PreparedPlayback, item: PlayerItem, itemID: String, episodeID: String?,
    generation: Int, fromStart: Bool, playAfterStart: Bool, initialPosition: Double?,
    extent: QueueStartExtent?
  ) async -> Bool {
    // Trim Silences' map, if ready within its budget, rides on the load. The wait can lose
    // ownership just as preparation can, so it is checked again.
    let pendingTrim = await prepareTrimBeforeLoad(for: prepared)
    guard ownsGeneration(generation) else {
      pendingTrim?.task.cancel()
      try? await sync.stopSession()
      return false
    }
    // Resolved for this title, never `player.state.rate`, which is whatever the previous title
    // played at. `.load` does not clamp what it is handed, so the resolved value is the validated
    // one (`PlaybackRateResolution`) rather than a raw stored number.
    let resolvedRate = rateCoordinator?.effectiveRate(forItemID: itemID) ?? player.state.rate
    // A queued chapter starts where the chapter does, whatever the book's saved or authorized
    // position: the listener asked for that chapter.
    let loadPosition =
      extent?.chapter?.start ?? (fromStart ? 0 : (initialPosition ?? prepared.startPosition))
    player.send(
      .load(
        item: item, initialGlobalPosition: loadPosition, rate: resolvedRate,
        trim: pendingTrim?.ready?.map))
    // Seeded before the load is published, for every source. A later stop uses it to tell the
    // current identity's accepted ticks from a position retained by an earlier one. Playhead
    // readers keyed to `loadedItemID` leave the persisted progress when the load is published, so
    // seeding later leaves them on a zero playhead until the first tick, which withdrew the item
    // detail progress bar and bounced the play capsule on the first, cold tap.
    setCurrentTime(loadPosition, settlesListPlayhead: true)
    setLoaded(
      itemID: itemID, episodeID: episodeID, isStreaming: prepared.source == .streaming,
      generation: generation)
    loadSkipRanges(for: prepared, generation: generation)
    loadLookBack(for: prepared)
    adoptTrim(pendingTrim, generation: generation)
    if freshLocalSessionOnNextPlay?.itemID == itemID,
      freshLocalSessionOnNextPlay?.episodeID == episodeID
    {
      freshLocalSessionOnNextPlay = nil
    }
    completedGeneration = nil
    eventBridge?.resetForwardingState()
    // Only a queue row decides the stop. Every other load leaves it to PlayerCore, which keeps a
    // chapter stop across a reload of the same title and drops it for any other. Sent before
    // play, so the stop is armed for the first second played.
    if let extent { sendSegment(for: extent) }
    if playAfterStart {
      player.send(.play)
    }
    return true
  }

  /// Applies the seek a start asked for before its session was ready.
  private func seekPendingStart(itemID: String, episodeID: String?, generation: Int) {
    guard let pendingStartSeek,
      pendingStartSeek.itemID == itemID,
      pendingStartSeek.episodeID == episodeID,
      pendingStartSeek.generation == generation
    else { return }
    self.pendingStartSeek = nil
    seek(itemID: itemID, toGlobalOffset: pendingStartSeek.offset)
  }

  /// Records a start once the session is durably open and handed to the player: the bookmark, the
  /// list's run, and the queue row.
  private func recordStartCompletion(
    itemID: String, episodeID: String?, generation: Int, origin: PlaybackStartFailure.Origin,
    run: RunIntent?, extent: QueueStartExtent?, displacing displaced: ListeningIdentity?
  ) async {
    // Written once per successful start, once the session is durably open and handed to the
    // player: never on the throw, cancelled or invalid-manifest paths. `displayedItem` is not
    // assigned here; it moves only through the `bookmarkTask` projection above, so screens see what
    // the store durably recorded.
    try? await bookmarkStore.setBookmark(itemID: itemID, episodeID: episodeID)

    // Logout can interleave with the bookmark write above. Its account-scoped teardown has
    // already won permanently, so no later queue mutation may escape this successful start.
    guard isQuiescedForLogout == false else { return }

    // The list's own start begins or advances its run only now that the start has taken.
    await recordRunStart(
      itemID: itemID, episodeID: episodeID, origin: origin, run: run, generation: generation)

    // Every successful ABS or RSS start consumes the title's whole-book or episode row, wherever
    // it sat, and a chapter row's start its own row. The book's other chapter rows stay. A swap's
    // displaced title returns to the front in the same write.
    guard let identity = ListeningIdentity.resolving(itemID: itemID, episodeID: episodeID) else {
      return
    }
    if let displaced, displaced != identity {
      _ = try? await listeningQueue.acknowledgeStarted(
        identity: identity, rowID: extent?.rowID, returning: displaced)
    } else {
      try? await listeningQueue.acknowledgeStarted(identity: identity, rowID: extent?.rowID)
    }
  }

  /// A queue row whose title is already loaded and resumable: no new session, since the open one
  /// is this title's. A chapter row seeks to its chapter; a whole-book row plays on from where the
  /// title stands, without the chapter stop a previous row may have left armed. Either consumes
  /// its row, which `performStart` would have done.
  private func startQueueRowInLoadedItem(
    itemID: String, episodeID: String?, extent: QueueStartExtent
  ) async {
    switch phase {
    case .playing: break
    default: await sync.notifyPlaybackPhase(.buffering)
    }
    guard isQuiescedForLogout == false, loadedItemID == itemID, loadedEpisodeID == episodeID else { return }
    if let chapter = extent.chapter {
      seek(itemID: itemID, toGlobalOffset: chapter.start)
    }
    sendSegment(for: extent)
    player.send(.play)
    if let identity = ListeningIdentity.resolving(itemID: itemID, episodeID: episodeID) {
      try? await listeningQueue.acknowledgeStarted(identity: identity, rowID: extent.rowID)
    }
  }

  private func sendSegment(for extent: QueueStartExtent) {
    if let chapter = extent.chapter {
      player.send(.setSegment(start: chapter.start, end: chapter.end))
    } else {
      player.send(.clearSegment)
    }
  }

  internal func ownsGeneration(_ generation: Int) -> Bool {
    playbackGeneration == generation && isQuiescedForLogout == false
  }

  /// Clears failure/preparing presentation only when the completing operation still owns it.
  /// A newer request has already installed its own identity and `.preparing` phase, while logout
  /// has already installed the terminal idle state; neither may be erased by an older completion.
  private func resetStartIfOwned(
    generation: Int, itemID: String, episodeID: String?, origin: PlaybackStartFailure.Origin,
    run: RunIntent? = nil, extent: QueueStartExtent? = nil, failureMessage: String? = nil
  ) {
    guard ownsGeneration(generation) else { return }
    if failureMessage != nil {
      failedStartIdentity = (itemID: itemID, episodeID: episodeID)
      failedStartRun = run
      failedStartExtent = extent
    }
    if origin.isAutomatic, failureMessage != nil {
      setPhase(.recoverableError)
    } else {
      setActive(itemID: nil, episodeID: nil)
      setPhase(.idle)
    }
    setStartFailure(failureMessage.map { PlaybackStartFailure(message: $0, origin: origin) })
  }

  /// Dismisses the current start failure without changing the playback session or its retained
  /// presentation state.
  public func dismissStartFailure() {
    setStartFailure(nil)
    failedStartIdentity = nil
    failedStartRun = nil
    failedStartExtent = nil
  }
}
