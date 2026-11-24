import Foundation
import Persistence
import PlayerCore
import SyncEngine

/// Promotion is a swap-and-seek onto an already-downloaded local file, not a gapless handover.
/// The short interruption is the accepted cost of promoting immediately; a podcast episode has no
/// track boundary to wait for.
extension PlaybackModel {

  /// Replaces the previous identity-scoped observation whenever `setLoaded` changes the source
  /// handed to PlayerCore. Opened only for a streamed item, so a local session or an idle model
  /// never keeps a download database observer alive.
  internal func updatePromotionObservation(
    itemID: String?, episodeID: String?, isStreaming: Bool
  ) {
    promotionObservationTask?.cancel()
    promotionObservationTask = nil
    deferredPromotion = nil

    guard isStreaming, let itemID, let downloadReading else { return }
    let generation = playbackGeneration

    if let episodeID {
      let key = EpisodeDownloadKey(itemID: itemID, episodeID: episodeID)
      let stream = downloadReading.observeEpisodeDownloadPresence()
      promotionObservationTask = Task { [weak self] in
        for await presence in stream {
          guard Task.isCancelled == false else { return }
          guard presence[key] == .completed else { continue }
          guard let self else { return }
          await self.handleCompletedDownload(
            itemID: itemID, episodeID: episodeID, generation: generation)
        }
      }
      return
    }

    let stream = downloadReading.observeItemDownloadStatus(itemId: itemID)
    promotionObservationTask = Task { [weak self] in
      for await status in stream {
        guard Task.isCancelled == false else { return }
        guard status == .completed else { continue }
        guard let self else { return }
        await self.handleCompletedDownload(itemID: itemID, episodeID: nil, generation: generation)
      }
    }
  }

  /// A completion observed while the player is unsettled is held until the first settled phase.
  /// `.seeking` is held so a promotion and a scrub do not reposition against each other.
  /// `.preparing` is PlayerCore's gapless auto-advance window, and swapping the item there would
  /// add a gap. Either way the swap happens just after the boundary. Any other ineligible phase
  /// (idle, ended, either error) means the listen is not continuing, so the deferral is dropped.
  internal func handlePromotionPhaseChange(_ nextPhase: Phase) {
    guard Self.isDeferringPhase(nextPhase) == false else { return }
    guard Self.isPromotionPhase(nextPhase) else {
      deferredPromotion = nil
      return
    }
    guard let deferred = deferredPromotion else { return }
    deferredPromotion = nil
    Task { [weak self] in
      await self?.handleCompletedDownload(
        itemID: deferred.itemID, episodeID: deferred.episodeID, generation: deferred.generation)
    }
  }

  /// The phases a completion waits out rather than being discarded by. Keep it narrow: a phase
  /// belongs here only if the same listen is expected to settle back into an eligible one.
  private static func isDeferringPhase(_ phase: Phase) -> Bool {
    phase == .seeking || phase == .preparing
  }

  private static func isPromotionPhase(_ phase: Phase) -> Bool {
    switch phase {
    case .playing, .paused, .buffering, .stalled: return true
    case .idle, .preparing, .seeking, .recoverableError, .unrecoverableError, .ended: return false
    }
  }

  private func ownsPromotion(
    itemID: String, episodeID: String?, generation: Int
  ) -> Bool {
    isQuiescedForLogout == false
      && generation == playbackGeneration
      && loadedPlaybackGeneration == generation
      && activeItemID == itemID
      && loadedItemID == itemID
      && activeEpisodeID == episodeID
      && loadedEpisodeID == episodeID
      && isStreamingSource
      && promotedGeneration != playbackGeneration
  }

  private func handleCompletedDownload(
    itemID: String, episodeID: String?, generation: Int
  ) async {
    guard Task.isCancelled == false,
      ownsPromotion(itemID: itemID, episodeID: episodeID, generation: generation)
    else { return }

    if Self.isDeferringPhase(phase) {
      deferredPromotion = (itemID: itemID, episodeID: episodeID, generation: generation)
      return
    }
    guard Self.isPromotionPhase(phase) else { return }

    await enqueuePromotion(itemID: itemID, episodeID: episodeID, generation: generation)
  }

  /// Promotions share the same operation tail as starts, so a download completion cannot enter
  /// SyncEngine between a start's preparation and its cleanup.
  private func enqueuePromotion(
    itemID: String, episodeID: String?, generation: Int
  ) async {
    let previousOperation = startOperationTail
    let operation = Task { [weak self] in
      await previousOperation?.value
      guard let self else { return }
      await self.performPromotion(
        itemID: itemID, episodeID: episodeID, generation: generation)
    }
    startOperationTail = operation
    await withTaskCancellationHandler {
      await operation.value
    } onCancel: {
      operation.cancel()
    }
  }

  private func performPromotion(
    itemID: String, episodeID: String?, generation: Int
  ) async {
    guard Task.isCancelled == false,
      ownsPromotion(itemID: itemID, episodeID: episodeID, generation: generation),
      Self.isPromotionPhase(phase)
    else { return }

    let wasPlaybackIntended = player.isPlaybackIntended
    let position = player.state.globalPosition
    guard
      let prepared = await sync.promoteStreamingSessionToLocalDownload(
        itemID: itemID, episodeID: episodeID, currentPosition: position,
        streamedDuration: player.state.item?.timeline.totalDuration
      )
    else { return }

    guard Task.isCancelled == false,
      ownsPromotion(itemID: itemID, episodeID: episodeID, generation: generation),
      Self.isPromotionPhase(phase)
    else {
      // The coordinator has already switched the durable session to local. Losing only the
      // PlayerCore swap is safe: the next start for this identity picks up the local session.
      return
    }

    guard prepared.source == .local,
      let item = try? Self.makePlayerItem(itemID: itemID, prepared: prepared)
    else { return }

    // A promoted episode is a single local file, so it can be trimmed from here on.
    let pendingTrim = await prepareTrimBeforeLoad(for: prepared)
    guard Task.isCancelled == false,
      ownsPromotion(itemID: itemID, episodeID: episodeID, generation: generation),
      Self.isPromotionPhase(phase)
    else {
      pendingTrim?.task.cancel()
      return
    }

    let livePosition = player.state.globalPosition
    let resolvedRate = rateCoordinator?.effectiveRate(forItemID: itemID) ?? player.state.rate
    playbackGeneration += 1
    let newGeneration = playbackGeneration
    player.send(
      .load(
        item: item, initialGlobalPosition: livePosition, rate: resolvedRate,
        trim: pendingTrim?.ready?.map))
    setLoaded(
      itemID: itemID, episodeID: episodeID, isStreaming: false, generation: newGeneration)
    loadSkipRanges(for: prepared, generation: newGeneration)
    loadLookBack(for: prepared)
    adoptTrim(pendingTrim, generation: newGeneration)
    completedGeneration = nil
    eventBridge?.resetForwardingState()
    promotedGeneration = newGeneration
    if wasPlaybackIntended { player.send(.play) }
  }
}
