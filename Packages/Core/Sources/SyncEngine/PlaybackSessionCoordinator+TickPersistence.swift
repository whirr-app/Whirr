import Foundation
import Persistence

extension PlaybackSessionCoordinator {
  /// Tries each persist branch in order and states which one took the tick. Every branch reports
  /// `notActive`, `persisted`, or `writeFailed`. A write that threw is never reported as handled
  /// (a failed `recordLocalTick` would silence the sessionless net and lose listening time); it
  /// falls through like an inactive branch, and the record naming the branch is emitted whatever
  /// the outcome (`PlaybackTickTrace`).
  @discardableResult
  func persistTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool
  ) -> PlaybackTickTrace.Record {
    var failedRoutes: [PlaybackTickTrace.Route] = []

    func finish(_ outcome: PlaybackTickTrace.Outcome) -> PlaybackTickTrace.Record {
      let record = PlaybackTickTrace.Record(
        outcome: outcome, failedRoutes: failedRoutes, itemID: itemID, episodeID: episodeID,
        position: currentTime)
      if Self.tracesTickOutcome(record.outcome) {
        emitTickRecord(record)
      }
      return record
    }

    switch persistCachedOnlineTick(
      itemID: itemID, episodeID: episodeID, currentTime: currentTime,
      listenedDelta: listenedDelta, isFinished: isFinished, isSeek: isSeek)
    {
    case .persisted: return finish(.persisted(.cachedOnline))
    case .writeFailed: failedRoutes.append(.cachedOnline)
    case .notActive, .suppressed: break
    }

    let rows: TickRows
    switch resolveTickRows(itemID: itemID, episodeID: episodeID) {
    case .resolved(let resolved): rows = resolved
    case .unresolved(let reason): return finish(.dropped(reason))
    }

    // A tick for any item other than this device's locally-active one is stale (e.g. a straggler
    // PlayerCore emitted as a switch was displacing it) and must not be attributed to whatever
    // session now occupies the slot. Checked once up front, then reused to identify whichever
    // kind of session (local or online) is active for it.
    switch persistLocalTickIfActive(
      accountId: rows.accountId, accountRecord: rows.accountRecord, itemRowId: rows.itemRowId,
      episodeRowId: rows.episodeRowId, currentTime: currentTime, listenedDelta: listenedDelta,
      isFinished: isFinished, isSeek: isSeek)
    {
    case .persisted: return finish(.persisted(.local))
    case .writeFailed: failedRoutes.append(.local)
    case .notActive, .suppressed: break
    }

    switch persistOnlineTickIfActive(
      accountId: rows.accountId, accountRecord: rows.accountRecord, itemID: itemID,
      episodeID: episodeID, itemRowId: rows.itemRowId, episodeRowId: rows.episodeRowId,
      currentTime: currentTime, listenedDelta: listenedDelta, isFinished: isFinished,
      isSeek: isSeek)
    {
    case .persisted: return finish(.persisted(.online))
    case .writeFailed: failedRoutes.append(.online)
    case .notActive, .suppressed: break
    }

    switch persistSessionlessTick(
      accountId: rows.accountId, itemID: itemID, episodeID: episodeID, itemRowId: rows.itemRowId,
      episodeRowId: rows.episodeRowId, accountRecord: rows.accountRecord, currentTime: currentTime,
      isFinished: isFinished)
    {
    case .persisted: return finish(.persisted(.sessionless))
    case .writeFailed:
      failedRoutes.append(.sessionless)
      return finish(.dropped(.everyWriteFailed))
    case .notActive:
      switch persistDisplacedTick(
        accountId: rows.accountId, itemID: itemID, episodeID: episodeID, itemRowId: rows.itemRowId,
        episodeRowId: rows.episodeRowId, accountRecord: rows.accountRecord, currentTime: currentTime,
        isFinished: isFinished)
      {
      case .persisted: return finish(.persisted(.displaced))
      case .writeFailed:
        failedRoutes.append(.displaced)
        return finish(.dropped(.everyWriteFailed))
      case .notActive: return finish(.dropped(.notPlayingThisItem))
      }
    case .suppressed: return finish(.dropped(.suppressedByVariant))
    }
  }

  /// One persist branch's answer. `writeFailed` and `notActive` are distinct: both fall through
  /// to the next branch, but only `writeFailed` is a fault worth a device-visible line.
  private enum TickBranch {
    case notActive
    case persisted
    case writeFailed
    /// The `ABS_VARIANT` scaffolding declined to attempt the write (sessionless branch only).
    case suppressed
  }

  private enum DisplacedTickBranch {
    case notActive
    case persisted
    case writeFailed
  }

  struct TickRows {
    let accountRecord: AccountRecord
    let accountId: Int64
    let itemRowId: Int64
    let episodeRowId: Int64?
  }

  enum TickRowsResolution {
    case resolved(TickRows)
    case unresolved(PlaybackTickTrace.DropReason)
  }

  /// Test seam for the tick trace; see `emitTickRecord`.
  func setTickRecordSink(_ sink: @escaping @Sendable (PlaybackTickTrace.Record) -> Void) {
    emitTickRecord = sink
  }

  /// Test seam for the durable tick writes; see `tickWriter`.
  func setTickWriter(_ writer: any PlaybackTickWriting) {
    tickWriter = writer
  }

  /// `ABS_VARIANT` is device-experiment scaffolding for measuring the sessionless net's write
  /// against its trace: `A` does neither, `B` traces only, `C` writes only. Unset (every ordinary
  /// run and every test), both happen.
  private static func tracesTickOutcome(_ outcome: PlaybackTickTrace.Outcome) -> Bool {
    switch ProcessInfo.processInfo.environment["ABS_VARIANT"] {
    case "A": return outcome != .dropped(.suppressedByVariant)
    case "C": return outcome != .persisted(.sessionless)
    default: return true
    }
  }

  private func persistCachedOnlineTick(
    itemID: String, episodeID: String?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool
  ) -> TickBranch {
    guard var target = cachedOnlineTickTarget, target.itemID == itemID,
      target.episodeID == episodeID, let sessionId = target.session.id
    else { return .notActive }

    let previousSegment = progressSegmentBySessionID[sessionId]
    let previousFinished = lastFinishedBySessionID[sessionId]
    let tick = buildTick(
      sessionId: sessionId, existing: target.session, accountRecord: target.accountRecord,
      itemRowId: target.itemRowId, currentTime: currentTime, listenedDelta: listenedDelta,
      isFinished: isFinished, isSeek: isSeek, advanceSequenceInStore: true)
    if let updated = try? tickWriter.recordNextTick(sessionId: sessionId, tick: tick) {
      target.session = updated
      cachedOnlineTickTarget = target
      return .persisted
    }
    progressSegmentBySessionID[sessionId] = previousSegment
    lastFinishedBySessionID[sessionId] = previousFinished
    cachedOnlineTickTarget = nil
    return .writeFailed
  }

  /// Reports which lookup missed: "this device has no account row" (a logout racing a tick) or
  /// "the server never sent us this item".
  func resolveTickRows(itemID: String, episodeID: String?) -> TickRowsResolution {
    guard let accountRecord = try? accountDAO.fetch(), let accountId = accountRecord.id else {
      return .unresolved(.noAccountRow)
    }
    guard let itemRow = try? itemDAO.fetchOne(accountId: accountId, serverItemId: itemID),
      let itemRowId = itemRow.id
    else { return .unresolved(.noItemRow) }

    let episodeRowId: Int64?
    if let episodeID {
      guard
        let episode = try? podcastEpisodeDAO.fetchOne(
          itemId: itemRowId, serverEpisodeId: episodeID),
        episode.accountId == accountId,
        let resolvedEpisodeRowId = episode.id
      else { return .unresolved(.noEpisodeRow) }
      episodeRowId = resolvedEpisodeRowId
    } else {
      episodeRowId = nil
    }
    return .resolved(
      TickRows(
        accountRecord: accountRecord, accountId: accountId, itemRowId: itemRowId,
        episodeRowId: episodeRowId))
  }

  private func persistLocalTickIfActive(
    accountId: Int64, accountRecord: AccountRecord, itemRowId: Int64, episodeRowId: Int64?,
    currentTime: Double, listenedDelta: Double, isFinished: Bool, isSeek: Bool
  ) -> TickBranch {
    guard let activeLocal = try? sessionStore.fetchActiveOfflineSession(accountId: accountId),
      activeLocal.itemId == itemRowId, activeLocal.podcastEpisodeId == episodeRowId,
      let sessionId = activeLocal.id
    else { return .notActive }

    // A local session's tick never creates an outbox row, so route to `recordLocalTick` instead
    // of `recordTick` whenever a local session, not an online one, is this item's active session.
    let tick = buildTick(
      sessionId: sessionId, existing: activeLocal, accountRecord: accountRecord, itemRowId: itemRowId,
      currentTime: currentTime, listenedDelta: listenedDelta, isFinished: isFinished, isSeek: isSeek)
    guard (try? tickWriter.recordLocalTick(sessionId: sessionId, tick: tick)) != nil else {
      return .writeFailed
    }
    return .persisted
  }

  private func persistOnlineTickIfActive(
    accountId: Int64, accountRecord: AccountRecord, itemID: String, episodeID: String?,
    itemRowId: Int64, episodeRowId: Int64?, currentTime: Double, listenedDelta: Double,
    isFinished: Bool, isSeek: Bool
  ) -> TickBranch {
    guard let existing = try? sessionStore.fetchActiveSession(accountId: accountId),
      let sessionId = existing.id, existing.itemId == itemRowId,
      existing.podcastEpisodeId == episodeRowId
    else { return .notActive }

    let tick = buildTick(
      sessionId: sessionId, existing: existing, accountRecord: accountRecord, itemRowId: itemRowId,
      currentTime: currentTime, listenedDelta: listenedDelta, isFinished: isFinished, isSeek: isSeek,
      advanceSequenceInStore: true)
    guard let updated = try? tickWriter.recordNextTick(sessionId: sessionId, tick: tick) else {
      return .writeFailed
    }
    cachedOnlineTickTarget = OnlineTickTarget(
      accountRecord: accountRecord, itemID: itemID, episodeID: episodeID,
      itemRowId: itemRowId, session: updated)
    return .persisted
  }

  /// The last resort under `persistTick`: no session of either kind is active for this item, but
  /// this device is still playing it, so the position is real listening that would otherwise be
  /// discarded silently. Admits only the item `performStart` most recently prepared. A
  /// switch-displaced straggler goes to `persistDisplacedTick` below; a straggler inside the
  /// `stragglerGrace` window after a stop stays dropped, while sustained ticks beyond it re-arm
  /// the retired item. After a logout quiesce nothing re-arms.
  ///
  /// Position only, never a session (`recordSessionlessTick` explains why). Diagnostics are loud:
  /// a session died underneath live audio, so `PlaybackTickTrace` marks every sessionless outcome
  /// noteworthy and `persistTick` emits the line.
  private func persistSessionlessTick(
    accountId: Int64, itemID: String, episodeID: String?, itemRowId: Int64, episodeRowId: Int64?,
    accountRecord: AccountRecord, currentTime: Double, isFinished: Bool
  ) -> TickBranch {
    let identity = ActivePlaybackItem(
      itemID: itemID, episodeID: episodeID, itemRowId: itemRowId, episodeRowId: episodeRowId,
      accountId: accountId)
    if activePlaybackItem != identity {
      // Not what this device started, unless a stop retired it and the ticks never stopped. Then
      // the audio is still playing and the stop was wrong. The same sustained-tick evidence
      // admits a coordinator created underneath process-lifetime audio. `quiesceForLogout`
      // retires through the same `performStop`, but ticks that outlive it belong to an account
      // mid-removal, so no amount of live audio re-arms across that boundary.
      if isQuiescedForLogout { return .notActive }
      let now = clock.now()
      if let retired = retiredPlaybackItem, retired.item == identity,
        now.timeIntervalSince(retired.stoppedAt) > Self.stragglerGrace
      {
        // The retired item proved live below.
      } else if activePlaybackItem == nil, displacedPlaybackItem == nil,
        retiredPlaybackItem == nil
      {
        guard let candidate = unarmedPlaybackCandidate, candidate.item == identity else {
          unarmedPlaybackCandidate = RetiredPlaybackItem(item: identity, stoppedAt: now)
          return .notActive
        }
        guard now.timeIntervalSince(candidate.stoppedAt) > Self.stragglerGrace else {
          return .notActive
        }
      } else {
        return .notActive
      }
      activePlaybackItem = identity
      retiredPlaybackItem = nil
      unarmedPlaybackCandidate = nil
    }

    // `A`/`B` are the no-write variants of the device experiment `tracesTickOutcome` documents.
    let variant = ProcessInfo.processInfo.environment["ABS_VARIANT"]
    if variant == "A" || variant == "B" { return .suppressed }

    guard
      (try? tickWriter.recordSessionlessTick(
        accountId: accountId, itemId: itemRowId, podcastEpisodeId: episodeRowId, serverItemId: itemID,
        tick: PlaybackTick(
          globalPosition: currentTime,
          isFinished: isFinished,
          deltaSecondsSinceLastTick: 0,
          localSequence: 0,
          originKey: accountRecord.clientUUID,
          segmentKey: "sessionless",
          now: clock.now()))) != nil
    else { return .writeFailed }
    return .persisted
  }

  /// The switch-specific last resort. Unlike `persistSessionlessTick`, this route is not part of
  /// the `ABS_VARIANT` experiment: it measures and preserves switch stragglers independently of the
  /// sessionless net. Full identity matching keeps a late tick from one item or episode from
  /// claiming another item's displaced slot.
  private func persistDisplacedTick(
    accountId: Int64, itemID: String, episodeID: String?, itemRowId: Int64, episodeRowId: Int64?,
    accountRecord: AccountRecord, currentTime: Double, isFinished: Bool
  ) -> DisplacedTickBranch {
    guard let displaced = displacedPlaybackItem, displaced.accountId == accountId,
      displaced.itemID == itemID, displaced.episodeID == episodeID,
      displaced.itemRowId == itemRowId, displaced.episodeRowId == episodeRowId
    else { return .notActive }

    guard
      (try? tickWriter.recordSessionlessTick(
        accountId: accountId, itemId: itemRowId, podcastEpisodeId: episodeRowId, serverItemId: itemID,
        tick: PlaybackTick(
          globalPosition: currentTime,
          isFinished: isFinished,
          deltaSecondsSinceLastTick: 0,
          localSequence: 0,
          originKey: accountRecord.clientUUID,
          segmentKey: "sessionless",
          now: clock.now()))) != nil
    else { return .writeFailed }
    return .persisted
  }

  /// The segment and local-sequence bookkeeping shared by the online (`recordTick`) and local
  /// (`recordLocalTick`) tick paths. A seek or finished/un-finished transition starts a fresh
  /// coalescing segment (irrelevant to a local tick, computed uniformly anyway). The local
  /// sequence advances from the higher of the session's and the item's durable progress sequence,
  /// so the first tick after a stop, relaunch or resume never looks stale against progress that
  /// outlived its session.
  private func buildTick(
    sessionId: Int64, existing: PlaybackSessionRecord, accountRecord: AccountRecord, itemRowId: Int64,
    currentTime: Double, listenedDelta: Double, isFinished: Bool, isSeek: Bool,
    advanceSequenceInStore: Bool = false
  ) -> PlaybackTick {
    let previousFinished = lastFinishedBySessionID[sessionId] ?? isFinished
    var segment = progressSegmentBySessionID[sessionId] ?? 0
    if isSeek || previousFinished != isFinished {
      segment += 1
    }
    progressSegmentBySessionID[sessionId] = segment
    lastFinishedBySessionID[sessionId] = isFinished

    let nextLocalSequence: Int64
    if advanceSequenceInStore {
      nextLocalSequence = 0
    } else {
      let progressSequence =
        (try? mediaProgressDAO.fetchCurrent(
          accountId: existing.accountId,
          identity: Self.progressIdentity(
            itemRowId: itemRowId, episodeRowId: existing.podcastEpisodeId)))?.localSequence ?? 0
      nextLocalSequence = max(existing.lastLocalSequence, progressSequence) + 1
    }

    return PlaybackTick(
      globalPosition: currentTime,
      isFinished: isFinished,
      deltaSecondsSinceLastTick: listenedDelta,
      localSequence: nextLocalSequence,
      originKey: accountRecord.clientUUID,
      segmentKey: "tick-\(segment)",
      now: clock.now()
    )
  }

  static func progressIdentity(
    itemRowId: Int64, episodeRowId: Int64?
  ) -> MediaProgressIdentity {
    if let episodeRowId {
      return .episode(itemId: itemRowId, podcastEpisodeId: episodeRowId)
    }
    return .item(itemId: itemRowId)
  }
}
