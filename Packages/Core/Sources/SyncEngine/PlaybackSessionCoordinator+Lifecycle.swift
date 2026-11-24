import ABSApi
import Foundation
import Persistence

extension PlaybackSessionCoordinator {
  public func stopSession() async throws {
    try await serialized {
      try await self.performStop()
    }
  }

  // MARK: - Lifecycle

  /// `.playing` and `.buffering` keep the session open with one immediate sync, and cadence
  /// continues under whatever bounded-background-task wrapping the caller applies (rule 7a). Every
  /// other phase (including `.idle`, where `performStop` is a safe no-op) takes the `stopSession`
  /// close path, atomically marking `closePending` then attempting close.
  ///
  /// `.buffering` keeps open because `PlaybackModel.mapCadencePhase` folds `.preparing`,
  /// `.buffering` and `.seeking` into it, so an ordinary scrub or stall reads as `.buffering`
  /// while audio runs; closing would leave live ticks nowhere to land and freeze the resume
  /// position at the second the screen locked. The opposite mistake (a session held open across a
  /// stall never resumed) costs nothing durable and is closed by the next stop, switch or
  /// fresh-process recovery; rule 7a prefers it.
  public func handleAppBackgrounded() async {
    guard Self.closesWhenBackgrounded(cadencePhase) else {
      await notifyImmediateSyncTrigger(.backgrounded)
      return
    }
    _ = try? await serialized {
      guard await self.shouldCloseWhenBackgrounded() else {
        await self.notifyImmediateSyncTrigger(.backgrounded)
        return
      }
      try await self.performStop()
    }
  }

  private func shouldCloseWhenBackgrounded() -> Bool {
    Self.closesWhenBackgrounded(cadencePhase)
  }

  /// Fresh-process recovery (see the protocol doc comment). Serialized against `startSession`/
  /// `stopSession` on the same device-keyed chain, so a caller that awaits this before calling
  /// `startSession` is guaranteed the reconciliation has committed.
  public func recoverOpenSessions() async {
    _ = try? await serialized {
      await self.performRecovery()
    }
  }

  /// The logout preflight (see the protocol doc comment). The flag is set before entering the
  /// serialized chain, as a plain actor-isolated assignment, so it takes effect for every call
  /// that has not yet started its synchronous prefix, without waiting on what is queued ahead.
  public func quiesceForLogout() async {
    isQuiescedForLogout = true
    displacedPlaybackItem = nil
    networkSubscriberTask?.cancel()
    networkSubscriberTask = nil
    _ = try? await serialized {
      try await self.performStop()
    }
  }

  // MARK: - Session-gone recovery

  /// The recovery half of `OutboxDrainer`'s session-gone-404 classification, called once
  /// `PlaybackSessionStore.markSessionGone` has marked the dead session and preserved its last
  /// position. Touches no position/delta: it only decides whether a replacement session opens.
  /// Quiet: a failed replacement `/play` is swallowed like other best-effort attempts here.
  ///
  /// Gated on whether anyone is still listening, as `handleAppBackgrounded` is: `.playing` and
  /// `.buffering` (which `PlaybackModel.mapCadencePhase` also produces for a scrub) mean a
  /// listener is waiting; declining there leaves a live listen with no session, and rule 6 puts
  /// listening stats on the session flow alone (`persistTick`'s sessionless net keeps only the
  /// position).
  ///
  /// The phase says something is playing, not that this item is. The dead session is often an
  /// earlier stream whose `/sync` or `/close` reached the server late. Recovering it would start a
  /// session for an item nobody is listening to, and `performStart`'s account-scoped
  /// close-before-play would close the live session; `activePlaybackItem` would then name the
  /// wrong item, even the sessionless net would reject ticks, and the rest of the listen would be
  /// discarded. A session gone for anything this device is not playing has nothing to recover:
  /// `markSessionGone` already preserved its last position (rule 11).
  public func recoverFromSessionGone(itemID: String, episodeID: String?) async {
    guard Self.closesWhenBackgrounded(cadencePhase) == false else { return }
    // Positive mismatch only: `activePlaybackItem` names what this process started, so when it
    // names something else there is a live listen to protect. `nil` means nothing this process
    // started is playing, so nothing is displaced and the phase guard above is the whole test.
    if let active = activePlaybackItem, active.itemID != itemID || active.episodeID != episodeID {
      return
    }
    _ = try? await serialized {
      try await self.performStart(itemID: itemID, episodeID: episodeID)
    }
  }

  // MARK: - Stop

  private func performStop() async throws {
    // The close path freezes `globalPosition` as read from the database, so flush the
    // accumulated tick first to freeze the last ticked position.
    flushPendingProgressTick()
    progressThrottle.reset()
    cachedOnlineTickTarget = nil
    if let active = activePlaybackItem {
      retiredPlaybackItem = RetiredPlaybackItem(item: active, stoppedAt: clock.now())
    }
    unarmedPlaybackCandidate = nil
    activePlaybackItem = nil
    displacedPlaybackItem = nil
    guard let accountId = try await accountDAO.fetchAsync()?.id else { return }
    try await closeActiveLocalSessionIfPresent(accountId: accountId)
    try await closeActiveSessionIfPresent(accountId: accountId)
  }

  // MARK: - Fresh-process recovery

  /// `/api/sessions/open` is opportunistic only: a `404` (route absent or not permitted) comes
  /// back as an empty list from `fetchOpenPlaybackSessions` without error (API-CONVENTIONS
  /// rule 6a), so this never depends on it finding anything. The reliable signal is this
  /// device's own locally persisted session id, confirmed via `GET /api/session/{id}`.
  private func performRecovery() async {
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id,
      let account = try? tokenAccount(for: accountRecord)
    else { return }

    if let existing = try? await sessionStore.fetchActiveSessionAsync(accountId: accountId),
      let existingId = existing.id
    {
      if let serverSessionId = existing.serverSessionId {
        let stillOpen: Bool
        do {
          stillOpen = try await client.fetchPlaybackSession(account: account, sessionID: serverSessionId) != nil
        } catch {
          // Ambiguous (transport/5xx/decode/etc.): never guess gone. Leave it locally active, as
          // close-ambiguity reconciliation does for an inconclusive check.
          stillOpen = true
        }
        if stillOpen == false {
          _ = try? sessionStore.markSessionGone(sessionId: existingId, now: clock.now())
        }
      } else {
        // Never confirmed server-side (a crash between `/play` returning and
        // `setServerSessionId`'s write). With no id to call `/close` with, `close()` alone would
        // leave `state == .active` forever, blocking a replacement `/play` against the schema's
        // one-active-session constraint. So `markSessionGone` frees the slot, as for the 404 case.
        _ = try? sessionStore.markSessionGone(sessionId: existingId, now: clock.now())
      }
    }

    // Best-effort supplement: closes a post-`/play` orphan this installation left open with no
    // local record. Filtered to rows whose `deviceInfo.deviceId` echoes this installation's
    // client UUID, so another device's session is never touched, and never closes the session
    // this device still tracks as active (reconciled just above).
    guard let openSessions = try? await client.fetchOpenPlaybackSessions(account: account) else { return }
    let stillTrackedServerSessionId =
      try? await sessionStore.fetchActiveSessionAsync(accountId: accountId)?.serverSessionId
    for openSession in openSessions
    where openSession.deviceID == accountRecord.clientUUID && openSession.id != stillTrackedServerSessionId {
      _ = try? await client.closePlaybackSession(account: account, sessionID: openSession.id)
    }
  }

  // MARK: - Close

  /// Freezes and durably persists `closePending` for the account's locally active session (if
  /// any), before requesting the ordered outbox drain (API-CONVENTIONS rule 9). Used by
  /// `stopSession` and a switch's freeze-former-session step. Only the drainer may send or
  /// acknowledge the close: it first sends every earlier sync row and includes the frozen final
  /// position in the body. Failure leaves the durable queue for retry.
  func closeActiveSessionIfPresent(accountId: Int64) async throws {
    // Whether or not anything gets closed, the locally active session's identity is changing
    // (stop, or a switch's freeze-former-session step). Cancel its cadence deadline before any
    // further `await` so it can never fire against whatever session replaces it.
    await resetCadenceForSessionChange()

    guard let existing = try await sessionStore.fetchActiveSessionAsync(accountId: accountId),
      let existingId = existing.id
    else { return }
    preparedBySessionID[existingId] = nil

    if existing.closePending {
      // A previous attempt already froze and queued this close. Requesting another drain is safe:
      // the outbox owns retry timing, per-entity ordering, and in-flight coalescing.
    } else {
      let closeTick = PlaybackSessionClose(
        globalPosition: existing.globalPosition, deltaSecondsSinceLastSend: 0,
        localSequence: existing.lastLocalSequence, now: clock.now())
      _ = try await sessionStore.closeAsync(sessionId: existingId, tick: closeTick)
    }

    await performFinalizationDrainRequest()
  }

  /// Local-session analogue of `closeActiveSessionIfPresent`. Freezes the active offline session
  /// (if any) to `.closedAwaitingUpload` and enqueues its one `localSessionUpload` outbox row,
  /// entirely locally (rule 10). Returns whether a session was closed; `performStart` fires the
  /// "offline-session close while non-offline" upload-drain trigger only then.
  @discardableResult
  func closeActiveLocalSessionIfPresent(accountId: Int64) async throws -> Bool {
    await resetCadenceForSessionChange()

    guard let existing = try await sessionStore.fetchActiveOfflineSessionAsync(accountId: accountId),
      let existingId = existing.id
    else { return false }
    preparedBySessionID[existingId] = nil

    let closeTick = PlaybackSessionClose(
      globalPosition: existing.globalPosition, deltaSecondsSinceLastSend: 0,
      localSequence: existing.lastLocalSequence, now: clock.now())
    _ = try await sessionStore.closeLocalSessionAsync(sessionId: existingId, tick: closeTick)
    return true
  }
}
