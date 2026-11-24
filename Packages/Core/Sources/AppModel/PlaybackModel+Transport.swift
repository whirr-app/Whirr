import CoreSupport
import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine

extension PlaybackModel {

  /// Every play-shaped entry point (the toggles below, and the lock-screen/Control Center commands
  /// that otherwise send bare `PlayerIntent`s past this model) must consult the
  /// `freshLocalSessionOnNextPlay` latch first: a play after a timer-owned close has to open a
  /// fresh local session, never resume audio no session records. `true` means the command was
  /// taken and the fresh start is underway.
  @discardableResult
  public func resumeThroughFreshLocalSessionIfLatched() -> Bool {
    guard let pending = freshLocalSessionOnNextPlay,
      isLoaded(itemID: pending.itemID, episodeID: pending.episodeID)
    else { return false }
    Task { [weak self] in
      await self?.start(itemID: pending.itemID, episodeID: pending.episodeID)
    }
    return true
  }

  /// Whether the next play of this loaded title goes through `start` rather than resuming in place.
  public func nextPlayStartsFresh(itemID: String, episodeID: String?) -> Bool {
    freshLocalSessionOnNextPlay?.itemID == itemID && freshLocalSessionOnNextPlay?.episodeID == episodeID
  }

  public func togglePlayPause() {
    if resumeThroughFreshLocalSessionIfLatched() { return }
    player.send(.toggle)
  }

  /// Toggles only when the requested item is the item PlayerCore has actually loaded.
  public func togglePlayPause(itemID: String) {
    guard activeItemID == itemID, loadedItemID == itemID, activeEpisodeID == loadedEpisodeID else {
      return
    }
    if resumeThroughFreshLocalSessionIfLatched() { return }
    player.send(.toggle)
  }

  /// Episode-scoped toggle, the counterpart to `isPlaybackIntended(for:episodeID:)`: a per-episode
  /// affordance must not pause a sibling episode of the same show.
  public func togglePlayPause(itemID: String, episodeID: String?) {
    guard isLoaded(itemID: itemID, episodeID: episodeID) else { return }
    if resumeThroughFreshLocalSessionIfLatched() { return }
    player.send(.toggle)
  }

  /// One tap for a transport surface: an active, loaded item toggles, so it pauses and never
  /// restarts; a retained-but-inactive item starts from its saved position. The branch every
  /// player surface shares, in one place.
  public func togglePlayPauseOrPlay(itemID: String, episodeID: String?) async {
    if activeItemID == itemID, loadedItemID == itemID {
      togglePlayPause(itemID: itemID)
    } else {
      await play(itemID: itemID, episodeID: episodeID)
    }
  }

  public func seek(toGlobalOffset offset: Double) {
    player.send(.seek(toGlobalOffset: offset))
  }

  /// Seeks only when the target is the item PlayerCore has actually loaded.
  public func seek(itemID: String, toGlobalOffset offset: Double) {
    guard activeItemID == itemID, loadedItemID == itemID, activeEpisodeID == loadedEpisodeID else {
      return
    }
    player.send(.seek(toGlobalOffset: offset))
  }

  /// Relative movement against the loaded item, and the only transport that may run past the end
  /// and finish the item (`PlayerIntent.skip`). Guarded on identity like `seek` above.
  public func skipLoaded(itemID: String, episodeID: String?, by delta: Double) {
    guard activeItemID == itemID, loadedItemID == itemID, activeEpisodeID == loadedEpisodeID,
      loadedEpisodeID == episodeID
    else { return }
    player.send(.skip(by: delta))
  }

  /// Moves to the adjacent chapter for the requested item. A loaded session delegates to
  /// PlayerCore, whose chapter-boundary and previous-chapter restart rules stay the source of
  /// truth. A retained item is prepared at the resolved chapter start and left paused; it must
  /// never briefly start audio.
  ///
  /// A cold start is allowed only for the bookmark the shell displays, and taps while that item is
  /// preparing are ignored. The start operation tail still protects cleanup if another item
  /// supersedes it.
  public func navigateChapter(
    itemID: String, episodeID: String? = nil, forward: Bool,
    fallbackChapterMap: PlaybackChapterMap
  ) async {
    if isLoaded(itemID: itemID, episodeID: episodeID) {
      player.send(forward ? .nextChapter : .previousChapter)
      return
    }

    // `activeItemID` moves before preparation completes. Do not let a repeated tap enqueue a
    // duplicate cold preparation or accidentally target the previous loaded item.
    if activeItemID == itemID, activeEpisodeID == episodeID,
      loadedItemID != itemID || loadedEpisodeID != episodeID
    {
      return
    }
    guard activeItemID == nil else { return }

    guard let bookmark = displayedItem,
      bookmark.serverItemId == itemID,
      bookmark.episodeID == episodeID
    else { return }

    let savedPosition = displayedItemPositionSeconds
    guard savedPosition.isFinite, savedPosition >= 0,
      let target = Self.chapterNavigationTarget(
        in: fallbackChapterMap, position: savedPosition, forward: forward)
    else { return }

    let requestedGeneration = playbackGeneration
    await start(
      itemID: itemID, episodeID: episodeID, fromStart: false, origin: .requested,
      forceFreshSession: false, expectedGeneration: requestedGeneration, playAfterStart: false,
      initialPosition: target.start)
  }

  private static func chapterNavigationTarget(
    in map: PlaybackChapterMap, position: Double, forward: Bool
  ) -> PlaybackChapter? {
    if forward { return map.nextChapter(after: position) }

    guard let current = map.currentChapter(at: position) else {
      return map.previousChapter(before: position)
    }
    if position - current.start > 3 {
      return current
    }
    return map.previousChapter(before: position) ?? current
  }

  /// The item-detail chapter list's and history list's "jump to a specific position" affordance.
  /// Seeks directly when `itemID` is already the active session, otherwise starts a fresh session
  /// first and then seeks. A failed `start` leaves nothing to seek (`activeItemID` stays `nil`),
  /// so no seek intent is sent in that case.
  public func startOrSeek(itemID: String, toGlobalOffset offset: Double, episodeID: String? = nil) async {
    if activeItemID == itemID, activeEpisodeID == episodeID {
      if loadedItemID != itemID || loadedEpisodeID != episodeID {
        pendingStartSeek = (
          itemID: itemID, episodeID: episodeID, generation: playbackGeneration, offset: offset
        )
        return
      }
      seek(itemID: itemID, toGlobalOffset: offset)
      return
    }
    await start(itemID: itemID, episodeID: episodeID)
    seek(itemID: itemID, toGlobalOffset: offset)
  }

  /// Retries the failure represented by the current model state. Preparation failures start the
  /// failed identity again; a dead streamed session goes through the same generation-owned start
  /// transaction as every other play request; an engine failure remains PlayerCore's concern.
  @discardableResult
  public func retry() -> Bool {
    if let failure = startFailure, let failedStartIdentity {
      return issueFreshRecovery(
        itemID: failedStartIdentity.itemID, episodeID: failedStartIdentity.episodeID,
        origin: failure.origin, run: failedStartRun, extent: failedStartExtent)
    }

    if isStreamingSource,
      let itemID = activeItemID,
      Self.isDeadSessionPhase(phase)
    {
      return issueFreshRecovery(itemID: itemID, episodeID: activeEpisodeID, origin: .requested)
    }

    player.send(.retry)
    return true
  }

  private func issueFreshRecovery(
    itemID: String, episodeID: String?, origin: PlaybackStartFailure.Origin,
    run: RunIntent? = nil, extent: QueueStartExtent? = nil
  ) -> Bool {
    guard stalledRecoveryTask == nil else { return false }
    let issuedGeneration = playbackGeneration
    let task = Task { [weak self] in
      guard let self else { return }
      guard Task.isCancelled == false, self.playbackGeneration == issuedGeneration else {
        self.stalledRecoveryTask = nil
        return
      }
      // Stop/logout must not cancel the start operation itself once this task has handed it off;
      // the start operation owns the generation check around every durable await.
      self.stalledRecoveryTask = nil
      await self.start(
        itemID: itemID, episodeID: episodeID, fromStart: false, origin: origin,
        forceFreshSession: true, expectedGeneration: issuedGeneration, run: run, extent: extent)
    }
    stalledRecoveryTask = task
    return true
  }

  // MARK: - Retained-item intents: play/skip a not-yet-active retained item

  /// Resumes the retained item named by `itemID` from its saved position. An already-active
  /// retained item is resumed synchronously, with no `await` before the `.play` intent reaches
  /// the player. An inactive one goes through `start`'s prepare-then-act path and then seeks to
  /// the saved position, since `startSession`'s manifest position is not necessarily this
  /// device's last-known one.
  public func play(itemID: String) async {
    guard let item = displayedItem, item.serverItemId == itemID else { return }
    await play(itemID: itemID, episodeID: item.episodeID)
  }

  public func play(itemID: String, episodeID: String?) async {
    if activeItemID == itemID, activeEpisodeID == episodeID,
      loadedItemID == itemID, loadedEpisodeID == episodeID,
      Self.isResumable(phase)
    {
      if freshLocalSessionOnNextPlay?.itemID == itemID,
        freshLocalSessionOnNextPlay?.episodeID == episodeID
      {
        await start(itemID: itemID, episodeID: episodeID)
        return
      }
      player.send(.play)
      return
    }
    // The shell already displays `activeItemID` while `start` is suspended. Do not let a tap
    // during that window operate on the previous loaded item or initiate a duplicate start.
    if activeItemID == itemID, loadedItemID != itemID { return }
    guard let item = displayedItem, item.serverItemId == itemID,
      item.episodeID == episodeID
    else { return }
    let savedPosition = displayedItemPositionSeconds
    await start(itemID: itemID, episodeID: episodeID)
    seek(itemID: itemID, toGlobalOffset: savedPosition)
  }
}
