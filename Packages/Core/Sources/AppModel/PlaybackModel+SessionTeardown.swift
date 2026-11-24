import CoreSupport
import Foundation
import Observation
import Persistence
import PlayerCore
import SyncEngine

/// Stopping playback and the logout boundary: the local stop, the two native-subscription stops,
/// the final RSS progress a stop carries, and the bounded model-level logout preflight.
extension PlaybackModel {

  /// Stops whatever is active, locally and on the server.
  public func stop() async {
    let finalRSSProgress = currentRSSProgressForTeardown()
    cancelStalledRecovery()
    playbackGeneration += 1
    let stopGeneration = playbackGeneration
    player.send(.stop)
    setActive(itemID: nil, episodeID: nil)
    setLoaded(itemID: nil, episodeID: nil, isStreaming: false)
    setPhase(.idle)
    await recordFinalRSSProgress(finalRSSProgress)
    // A replacement may start while either dependency call is suspended. Only the stop generation
    // may send the unkeyed close; otherwise the router would correctly apply it to the replacement.
    guard ownsGeneration(stopGeneration) else { return }
    await sync.notifyImmediateSyncTrigger(.closing)
    guard ownsGeneration(stopGeneration) else { return }
    try? await sync.stopSession()
  }

  /// Stops an active device-owned RSS episode for the native-subscriptions switch. The final
  /// position must be written while the RSS identity is still installed: `stop()` clears
  /// identities before it asks the sync router to close. ABS playback never enters this
  /// path, so its existing stop behavior is unchanged.
  public func stopForNativeSubscriptionsDisable() async {
    guard
      let itemID = activeItemID,
      activeEpisodeID != nil,
      PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil
    else { return }

    let expectedStopGeneration = playbackGeneration &+ 1
    await stop()
    // The feature toggle owns only the RSS generation it observed, never presentation installed by
    // an ABS (or later RSS) start while the final local position was being persisted.
    guard playbackGeneration == expectedStopGeneration else { return }
    // Native disable is the explicit exception to the normal retained-bookmark stop behavior:
    // the feed remains subscribed and its episode state remains durable, but the mini-player must
    // disappear and re-enabling must not start anything automatically.
    setDisplayedItem(nil)
    refreshNowPlayingIdentity()
  }

  /// Stops only the exact device-owned feed the user has confirmed they want to unfollow. Unlike
  /// the ordinary Stop control, this propagates a close failure: deleting the feed would otherwise
  /// remove the episode rows underneath a session the playback stack still owns. Identity remains
  /// installed on failure so a second confirmed attempt retries the close instead of mistaking the
  /// failed stop for an already-idle player.
  public func stopForNativeFeedUnfollow(itemID: String) async throws {
    guard PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil else { return }
    try Task.checkCancellation()

    // `start` publishes its requested identity before preparation and leaves the old PlayerCore
    // item loaded until the replacement is ready. If that old item is the feed being removed, its
    // start transition owns retiring the old session; wait for it rather than sending an unkeyed
    // stop that could land after the replacement. A failed replacement leaves the old item loaded,
    // in which case the stable generation falls through to the explicit close below.
    while loadedItemID == itemID, activeItemID != itemID {
      let observedGeneration = playbackGeneration
      let pendingStart = startOperationTail
      await pendingStart?.value
      try Task.checkCancellation()
      if loadedItemID != itemID { return }
      guard playbackGeneration != observedGeneration else { break }
    }

    // The inverse window is a target request preparing over an unrelated loaded item. Invalidate
    // only that request, then drain its operation so a cancellation-insensitive `startSession`
    // cannot return after the feed has been deleted and install the target. PlayerCore is
    // untouched; if no newer request superseded this cancellation, restore presentation to what
    // is still loaded.
    if activeItemID == itemID, loadedItemID != itemID {
      let pendingStart = startOperationTail
      cancelStalledRecovery()
      playbackGeneration += 1
      let cancellationGeneration = playbackGeneration
      await pendingStart?.value
      if ownsGeneration(cancellationGeneration), activeItemID == itemID, loadedItemID != itemID {
        if let loadedItemID {
          setActive(itemID: loadedItemID, episodeID: loadedEpisodeID)
          setPhase(Self.mapPhase(player.state.phase))
        } else {
          setActive(itemID: nil, episodeID: nil)
          setPhase(.idle)
        }
        if failedStartIdentity?.itemID == itemID {
          failedStartIdentity = nil
          failedStartRun = nil
          failedStartExtent = nil
          setStartFailure(nil)
        }
      }
      try Task.checkCancellation()
      return
    }

    guard loadedItemID == itemID, loadedEpisodeID != nil else { return }
    let finalRSSProgress = currentLoadedRSSProgressForTeardown(itemID: itemID)
    cancelStalledRecovery()
    playbackGeneration += 1
    let stopGeneration = playbackGeneration
    await recordFinalRSSProgress(finalRSSProgress)

    do {
      try requireUnfollowLoadedStopOwnership(generation: stopGeneration, itemID: itemID)
      try Task.checkCancellation()
      await sync.notifyImmediateSyncTrigger(.closing)
      try requireUnfollowLoadedStopOwnership(generation: stopGeneration, itemID: itemID)
      try Task.checkCancellation()
      try await sync.stopSession()
      // Once the durable close succeeds, finish the local stop even if this task was cancelled in
      // flight. The caller checks cancellation again before deletion; leaving a closed session
      // presented as live would instead make Retry target a resource that no longer exists.
      try requireUnfollowLoadedStopOwnership(generation: stopGeneration, itemID: itemID)
    } catch {
      if ownsGeneration(stopGeneration), loadedItemID == itemID {
        // No PlayerCore stop was sent, so the loaded item is still coherent and resumable. Advance
        // its event token to this retained generation so later progress is not rejected as stale.
        loadedPlaybackGeneration = stopGeneration
      }
      throw error
    }

    player.send(.stop)
    setLoaded(itemID: nil, episodeID: nil, isStreaming: false)
    if activeItemID == itemID {
      setActive(itemID: nil, episodeID: nil)
      setPhase(.idle)
    }
  }

  private func requireUnfollowLoadedStopOwnership(generation: Int, itemID: String) throws {
    guard ownsGeneration(generation), loadedItemID == itemID else { throw CancellationError() }
  }

  private func cancelStalledRecovery() {
    stalledRecoveryTask?.cancel()
    stalledRecoveryTask = nil
  }

  // MARK: - Logout preflight

  /// Stops accepting new playback intents, stops local playback, and makes the bounded
  /// server-close attempt (`PlaybackSyncing.quiesceForLogout`, wrapped in one bounded background
  /// task). The model-level half of the process-wide logout boundary; does not call
  /// `AccountLifecycle.logout()`. `quiesceForLogout` always returns normally, so a failed close
  /// never blocks the removal that follows; `logout()`'s own throw (server-side confirmation only,
  /// SECURITY.md rule 8) still propagates.
  public func prepareForLogout() async {
    let finalRSSProgress = currentRSSProgressForTeardown()
    cancelStalledRecovery()
    playbackGeneration += 1
    markQuiescedForLogout()
    player.send(.stop)
    setActive(itemID: nil, episodeID: nil)
    setLoaded(itemID: nil, episodeID: nil, isStreaming: false)
    setPhase(.idle)
    eventBridge?.stop()
    // The retained item is account-scoped like the bookmark row it projects, so it is cleared
    // here and the observation cancelled outright. A bookmark emission already in flight when
    // `logout()` was called then cannot land afterwards and resurrect it.
    bookmarkTask?.cancel()
    nativeSubscriptionsTask?.cancel()
    setDisplayedItem(nil)
    refreshNowPlayingIdentity()
    await recordFinalRSSProgress(finalRSSProgress)
    await runBoundedCloseAttempt { [sync] in
      await sync.quiesceForLogout()
    }
  }

  /// Waits for terminal event-consumer cancellation after an in-flight dependency call returns.
  /// Logout itself uses bounded SyncEngine quiescence and does not wait on cancellation-insensitive
  /// work, but lifecycle tests use this barrier instead of scheduler timing assumptions.
  internal func waitForEventBridgeTermination() async {
    await eventBridge?.waitForTermination()
  }

  /// Monotonic PlayerCore sequence last consumed by ingress, exposed internally so lifecycle tests
  /// can use a source-order barrier rather than scheduler yields.
  internal var lastObservedPlayerEventSequence: Int? {
    eventBridge?.lastObservedSequence
  }

  /// Runs the shared playback preflight, then invokes the already-confirmed destructive account
  /// lifecycle logout. Settings uses `prepareForLogout()` through its injected boundary so the
  /// account call is not duplicated there.
  public func logout() async throws {
    await prepareForLogout()
    try await account.logout()
  }

  /// Mirrors `AppLifecycle.runBoundedBackgroundTask`'s begin/end/cancel-on-expiration shape from
  /// the public `beginBackgroundTask`/`endBackgroundTask` primitives. The original is internal to
  /// SyncEngine, and a small duplicate is cheaper than widening its visibility for a second
  /// caller.
  private func runBoundedCloseAttempt(_ operation: @escaping @Sendable () async -> Void) async {
    let task = Task { await operation() }
    let token = appLifecycle.beginBackgroundTask { task.cancel() }
    _ = await task.value
    appLifecycle.endBackgroundTask(token)
  }

  /// Captures the last local playhead before teardown clears the model's identity.
  private func currentRSSProgressForTeardown() -> PlaybackTeardownProgress? {
    guard let itemID = activeItemID, let episodeID = activeEpisodeID else { return nil }
    return PlaybackTeardownProgress.capture(
      itemID: itemID, episodeID: episodeID, loadedItemID: loadedItemID,
      loadedEpisodeID: loadedEpisodeID, playhead: player.state.globalPosition,
      currentTime: currentTime, phase: player.state.phase)
  }

  /// The unfollow path can observe the target still loaded behind a replacement request. Capture
  /// that exact loaded identity rather than requiring it to remain the model's active presentation.
  private func currentLoadedRSSProgressForTeardown(itemID: String) -> PlaybackTeardownProgress? {
    guard let episodeID = loadedEpisodeID else { return nil }
    return PlaybackTeardownProgress.capture(
      itemID: itemID, episodeID: episodeID, loadedItemID: loadedItemID,
      loadedEpisodeID: loadedEpisodeID, playhead: player.state.globalPosition,
      currentTime: currentTime, phase: player.state.phase)
  }

  private func recordFinalRSSProgress(_ progress: PlaybackTeardownProgress?) async {
    guard let progress else { return }
    await sync.recordProgressTick(
      itemID: progress.itemID, episodeID: progress.episodeID, currentTime: progress.currentTime,
      listenedDelta: 0, isFinished: progress.isFinished, isSeek: false, sleepTimerExpired: false)
  }
}
