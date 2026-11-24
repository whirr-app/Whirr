import Foundation

extension PlaybackSessionCoordinator {
  static func closesWhenBackgrounded(_ phase: PlaybackCadencePhase) -> Bool {
    switch phase {
    case .playing, .buffering: false
    case .paused, .stopped, .idle: true
    }
  }

  // MARK: - Cadence

  /// `.playing` (re)starts a fresh 15/60 s periodic deadline, never a partially elapsed one, since
  /// `scheduler.reschedule` always cancels then schedules. Every non-playing phase cancels the
  /// deadline. Pause's immediate drain is a separate `.paused` trigger sent only after AppModel
  /// has persisted the pause event's final tick (API-CONVENTIONS rule 7).
  public func notifyPlaybackPhase(_ phase: PlaybackCadencePhase) async {
    phaseNotificationEpoch += 1
    cadencePhase = phase
    switch phase {
    case .playing:
      await scheduleNextPeriodicDrain()
      await reopenSessionIfResumedWithoutOne()
    case .paused:
      cadenceRecorder.interrupted()
      await scheduler.cancelPending()
    case .buffering, .stopped, .idle:
      cadenceRecorder.interrupted()
      await scheduler.cancelPending()
    }
  }

  public nonisolated func willStartPlayback(itemID: String) {
    _ = itemID
    // The ABS coordinator owns one origin, so there is no route to prepare.
  }

  /// A `.playing` notification is the one signal every resume origin shares (player, lock screen,
  /// Control Center, headphone taps). With no active playback item but a retired one, audio is
  /// running for a listen whose session a stop already closed (a close while backgrounded-and-
  /// paused then resumed from the lock screen, or a timer-owned close whose next play missed
  /// AppModel's fresh-session latch). The sessionless net keeps the position honest, but listening
  /// stats live on the session flow alone (API-CONVENTIONS rule 6). Reopening here, before the
  /// event bridge records the resumed ticks (it forwards them only after the phase change), puts
  /// the rest of the listen back on the session flow.
  ///
  /// A genuine stop cannot reach this: stopping unloads the engine, so no `.playing` phase can
  /// follow, and the bridge drops stale envelopes. Logout is guarded explicitly. Best-effort like
  /// `recoverFromSessionGone`: a failed reopen (say, offline streaming) leaves the sessionless net.
  private func reopenSessionIfResumedWithoutOne() async {
    guard isQuiescedForLogout == false, activePlaybackItem == nil,
      let retired = retiredPlaybackItem
    else { return }
    let epochAtResume = phaseNotificationEpoch
    let retiredItem = retired.item
    _ = try? await serialized {
      try await self.performResumeReopen(of: retiredItem, epochAtResume: epochAtResume)
    }
  }

  private func performResumeReopen(
    of retiredItem: ActivePlaybackItem, epochAtResume: Int
  ) async throws {
    // Re-checked on the chain: a start or stop queued ahead of this may have claimed or
    // re-retired the slot while the reopen waited its turn.
    guard isQuiescedForLogout == false, activePlaybackItem == nil,
      let current = retiredPlaybackItem, current.item == retiredItem
    else { return }
    _ = try await performStart(itemID: retiredItem.itemID, episodeID: retiredItem.episodeID)
    // performStart's close-before-play step reset the cadence phase to `.idle` for a session
    // change this reopen initiated itself. Left there, the next backgrounding would close the
    // fresh session under live audio. Restore `.playing` unless a newer notification landed
    // mid-reopen, whose phase must win.
    if phaseNotificationEpoch == epochAtResume {
      cadencePhase = .playing
      await scheduleNextPeriodicDrain()
    }
  }

  /// Tick-path twin of `reopenSessionIfResumedWithoutOne`, for a close no phase change follows. A
  /// resume racing an in-flight close never fires the hook above: `.playing` lands while the item
  /// is still active, and once the close completes the sessionless net's re-arm claims
  /// `activePlaybackItem` and clears `retiredPlaybackItem`, so no later phase can match. A tick
  /// persisted on the sessionless route is the net's own proof of live audio with no session
  /// (its admission bar is sustained ticks past `stragglerGrace`), so the first such tick ends
  /// the drain into position-only writes. The cadence phase is not consulted: the racing close's
  /// `resetCadenceForSessionChange` clobbers a live `.playing` to `.idle`.
  ///
  /// Already on the serialized chain (called from `recordProgressTick`'s closure), so it calls
  /// `performStart` directly, not a nested `serialized`. Best-effort: a failed start leaves the
  /// net as it was and the next sessionless tick tries again.
  func reopenSessionAfterSessionlessTick(itemID: String, episodeID: String?) async {
    // Re-checked despite following the persist in the same closure: the actor can interleave
    // direct calls (a phase notification, a quiesce) between that call and this one.
    guard isQuiescedForLogout == false,
      let armed = activePlaybackItem, armed.itemID == itemID, armed.episodeID == episodeID
    else { return }
    let epochAtResume = phaseNotificationEpoch
    guard (try? await performStart(itemID: itemID, episodeID: episodeID)) != nil else { return }
    // Same restoration as `performResumeReopen`. The sustained ticks show audio is playing, so
    // `.playing` is restored even when the racing close had clobbered the phase, unless a newer
    // notification landed mid-start, whose phase must win.
    if phaseNotificationEpoch == epochAtResume {
      cadencePhase = .playing
      await scheduleNextPeriodicDrain()
    }
  }

  /// Test seam for the cadence trace (see `emitCadenceRecord`).
  func setCadenceRecordSink(_ sink: @escaping @Sendable (DrainCadenceTrace.Record) -> Void) {
    emitCadenceRecord = sink
  }

  /// Every case requests one immediate drain (API-CONVENTIONS rule 7). Which boundary fired is not
  /// distinguished downstream, and cadence output never encodes `/sync`/`/close` policy.
  /// Backgrounding does not touch the scheduler: active `.playing` cadence continues underneath
  /// it (rule 7a).
  public func notifyImmediateSyncTrigger(_ trigger: PlaybackImmediateSyncTrigger) async {
    await performDrainRequest()
  }

  /// The one expression deciding the periodic interval, so the trace's `nominal` cannot drift from
  /// the deadline actually scheduled.
  private var cadenceInterval: TimeInterval {
    networkSnapshot.isDegraded ? Self.degradedCadenceInterval : Self.normalCadenceInterval
  }

  func scheduleNextPeriodicDrain() async {
    let interval = cadenceInterval
    cadenceRecorder.scheduled(nominal: interval)
    await scheduler.reschedule(after: interval) { [weak self] in
      await self?.firePeriodicDrain()
    }
  }

  private func firePeriodicDrain() async {
    // A cancelled deadline cannot reach this in production (the scheduler contract guarantees a
    // cancelled `action` never runs). The guard covers fakes that fire without honouring
    // cancellation, and a deadline acting on a phase that changed between scheduling and firing.
    guard cadencePhase == .playing else { return }
    // Traced here, not in `performDrainRequest`: the interval measured is the cadence deadline,
    // which fires whether or not its drain coalesces onto one in flight, and immediate triggers
    // share that seam and would interleave short intervals into the series.
    emitCadenceRecord(
      cadenceRecorder.fired(
        now: clock.now(),
        condition: DrainCadenceTrace.Condition(
          isLowPowerMode: networkSnapshot.isLowPowerMode,
          isConstrainedOrCellular: networkSnapshot.isConstrainedOrCellular)))
    // Schedule the next deadline before the request so the drain's round-trip overlaps the
    // period. The other order biased a 15 s interval by +1.0 s on a LAN and stretched one to
    // 127.5 s across a Wi-Fi to cellular handover. Deadlines falling during a stall still fire and
    // coalesce onto the in-flight drain, costing one catch-up request (rule 14). It also lets a
    // phase change win: `.paused`/`.stopped` cancel while the drain is suspended, and nothing
    // here reschedules behind them.
    await scheduleNextPeriodicDrain()
    await performDrainRequest()
  }

  /// Reacts only to a change in the reduced degraded/normal boundary. A duplicate emission (same
  /// booleans, or a different pair that is equally (non)degraded) does nothing, so entering or
  /// leaving a degraded condition is the only thing that cancels and reschedules a fresh full
  /// interval from the change instant. Never sends eagerly.
  func handleNetworkConditionsChange(_ snapshot: NetworkConditionsSnapshot) async {
    guard isQuiescedForLogout == false else { return }
    guard snapshot != networkSnapshot else { return }
    let wasDegraded = networkSnapshot.isDegraded
    networkSnapshot = snapshot
    guard cadencePhase == .playing, snapshot.isDegraded != wasDegraded else { return }
    // Playback never stopped, but the trace series still breaks: the fresh interval runs from the
    // change instant, so the next drain follows its predecessor by the elapsed remainder plus the
    // whole new nominal. Below the guard because a change that reschedules nothing breaks nothing.
    cadenceRecorder.interrupted()
    await scheduleNextPeriodicDrain()
  }

  /// Cancels any pending periodic deadline and drops the cadence phase back to `.idle`. Called
  /// whenever the locally active session changes identity (stop, or a switch's freeze-former-
  /// session step) so a former session's deadline can never fire against its successor.
  func resetCadenceForSessionChange() async {
    // The item-switch half of the trace's interruption reset. This path never goes through
    // `notifyPlaybackPhase`, so the phase-side reset alone would miss it.
    cadenceRecorder.interrupted()
    await scheduler.cancelPending()
    cadencePhase = .idle
  }

  /// Coalesces concurrent callers (mirrors `CoverImageClient`'s in-flight pattern). A trigger
  /// during a running `requestDrain` marks `drainRequestedAgain` instead of starting a second
  /// call, and one follow-up runs once the in-flight call returns. Only co-incident triggers
  /// collapse; a later one starts its own call.
  private func performDrainRequest() async {
    // Whatever asked for this drain (pause, an immediate trigger, the periodic cadence) wants the
    // server to see current state, so the accumulated tick must be durable in the outbox before
    // the drain reads it.
    flushPendingProgressTick()
    if drainInFlight {
      drainRequestedAgain = true
      return
    }
    drainInFlight = true
    await requestDrain()
    drainInFlight = false
    if drainRequestedAgain {
      drainRequestedAgain = false
      await performDrainRequest()
      return
    }
    let waiters = drainCompletionWaiters
    drainCompletionWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  /// Requests the same coalesced drain as cadence, but does not return until every request that
  /// arrived during the current drain cycle has completed. Session finalization needs this barrier
  /// before a switch may attempt to occupy the active-session slot with its replacement.
  func performFinalizationDrainRequest() async {
    flushPendingProgressTick()
    guard drainInFlight else {
      await performDrainRequest()
      return
    }
    drainRequestedAgain = true
    await withCheckedContinuation { continuation in
      drainCompletionWaiters.append(continuation)
    }
  }
}
