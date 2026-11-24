import ABSApi
import Foundation
import Persistence

extension PlaybackSessionCoordinator {
  public func startSession(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    try await serialized {
      try await self.performStart(itemID: itemID, episodeID: episodeID)
    }
  }

  /// Off the device-keyed serialization chain: it starts and closes no session, only re-stamps a
  /// header for the active one. On the chain, a stalled `/play` or `/close` would hold up the call
  /// a stalled listener is waiting on. Actor isolation still covers the `preparedBySessionID`
  /// update below.
  public func renewStreamAuthorization() async throws -> PlaybackStreamAuthorization? {
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id
    else { return nil }
    guard let active = try? await sessionStore.fetchActiveSessionAsync(accountId: accountId),
      active.closePending == false, let sessionId = active.id
    else { return nil }
    // A local session's tracks are app-container file URLs that never carried a Bearer; renewing
    // for one would spend a token rotation on a resource that cannot 401.
    if let prepared = preparedBySessionID[sessionId], prepared.source == .local { return nil }

    let account = try tokenAccount(for: accountRecord)
    let renewed = try await client.renewPlaybackStreamAuthorization(account: account)
    // Keep the cached preparation in step: an idempotent `startSession` for this active item
    // returns it verbatim, and handing back the credential that just 401'd would undo the renewal.
    if let prepared = preparedBySessionID[sessionId] {
      preparedBySessionID[sessionId] = PreparedPlayback(
        itemID: prepared.itemID, episodeID: prepared.episodeID, startPosition: prepared.startPosition,
        duration: prepared.duration, tracks: prepared.tracks, chapters: prepared.chapters,
        source: prepared.source, streamAuthorization: renewed)
    }
    return renewed
  }

  // MARK: - Start / switch / resume

  func performStart(itemID: String, episodeID: String?) async throws -> PreparedPlayback {
    let context = try await resolveStartContext(itemID: itemID, episodeID: episodeID)

    // A fully-downloaded item always plays as a complete local session, even online (see the
    // ARCHITECTURE.md decision log). Resolved before constructing a `TokenAccount` or touching
    // the network, so the local resume path below never does either.
    let resolution = try await resolveSource(
      accountId: context.accountId, itemID: itemID, itemRowId: context.itemRowId,
      episodeRowId: context.episodeRowId)

    if let prepared = await resumeInPlaceIfPossible(
      resolution: resolution, itemID: itemID, episodeID: episodeID,
      accountId: context.accountId, itemRowId: context.itemRowId, episodeRowId: context.episodeRowId)
    {
      return prepared
    }

    // Not an in-place resume: freeze and close whichever session (local, online or neither) is
    // active before starting anything new. Close-before-play ordering applies whichever side
    // (local or streaming) is on either end of the switch, so both closes are attempted
    // unconditionally. Each is a no-op if its kind of session is not the active one.
    let closedLocalSession = try await closeActiveLocalSessionIfPresent(accountId: context.accountId)
    let account = try tokenAccount(for: context.accountRecord)
    try await closeActiveSessionIfPresent(accountId: context.accountId)

    switch resolution {
    case .local(let material):
      return try await startFreshLocalSession(
        accountId: context.accountId, itemID: itemID, itemRowId: context.itemRowId, episodeID: episodeID,
        episodeRowId: context.episodeRowId, material: material)
    case .streaming(let wasDemotedFromCompleteLocal):
      // Trigger for draining an offline session closed while conditions are non-offline. Fires
      // only when this call closed a locally-active offline session and is now starting a
      // streaming session, not on every streaming start.
      if closedLocalSession {
        await requestLocalSessionUploadDrain()
      }
      do {
        return try await performOnlineStart(
          itemID: itemID, episodeID: episodeID, accountRecord: context.accountRecord,
          accountId: context.accountId, account: account, itemRowId: context.itemRowId,
          episodeRowId: context.episodeRowId)
      } catch {
        // An item demoted from a complete local download (the integrity sweep found it missing)
        // streams as a first attempt; if that fails too there is no way to play it, which
        // deserves a distinct error. Likewise a never-downloaded item with the server unreachable:
        // no retry can succeed until it returns, so not the generic "Try again.".
        if wasDemotedFromCompleteLocal
          || PlaybackStartFailureClassification.isServerUnreachable(error)
        {
          throw PlaybackCoordinatorError.unplayableOffline(itemID: itemID)
        }
        throw error
      }
    }
  }

  private func resolveStartContext(
    itemID: String, episodeID: String?
  ) async throws -> (
    accountRecord: AccountRecord, accountId: Int64, itemRowId: Int64, episodeRowId: Int64?
  ) {
    guard isQuiescedForLogout == false else {
      throw PlaybackCoordinatorError.quiescedForLogout
    }
    // A switch's freeze-former-session step reads the session's `globalPosition`, so the
    // accumulated tick must be durable first. Whatever session is active next starts its
    // throttle fresh.
    flushPendingProgressTick()
    progressThrottle.reset()
    cachedOnlineTickTarget = nil
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      throw PlaybackCoordinatorError.notAuthenticated
    }
    guard let itemRow = try? await itemDAO.fetchOneAsync(accountId: accountId, serverItemId: itemID),
      let itemRowId = itemRow.id
    else {
      throw PlaybackCoordinatorError.unknownItem(itemID)
    }
    let episodeRowId: Int64?
    if let episodeID {
      guard
        let episode = try? await podcastEpisodeDAO.fetchOneAsync(
          itemId: itemRowId, serverEpisodeId: episodeID),
        episode.accountId == accountId,
        let resolvedEpisodeRowId = episode.id
      else {
        throw PlaybackCoordinatorError.unknownPodcastEpisode(
          itemID: itemID, episodeID: episodeID)
      }
      episodeRowId = resolvedEpisodeRowId
    } else {
      episodeRowId = nil
    }

    let nextPlaybackItem = ActivePlaybackItem(
      itemID: itemID, episodeID: episodeID, itemRowId: itemRowId, episodeRowId: episodeRowId,
      accountId: accountId)
    // Recorded here rather than on each success path because every one means this item plays
    // next, and a `performStart` that throws past this point produces no playback and so no
    // ticks for this marker to admit. An idempotent restart keeps the existing displaced slot
    // because it displaced no new item.
    if activePlaybackItem != nextPlaybackItem {
      displacedPlaybackItem = activePlaybackItem
    }
    // A fresh start supersedes whatever the last stop retired: a straggler for it is stale from
    // here, and `displacedPlaybackItem` is the slot that covers switches.
    retiredPlaybackItem = nil
    unarmedPlaybackCandidate = nil
    activePlaybackItem = nextPlaybackItem
    return (
      accountRecord: accountRecord, accountId: accountId, itemRowId: itemRowId,
      episodeRowId: episodeRowId
    )
  }

  private func resumeInPlaceIfPossible(
    resolution: SourceResolution, itemID: String, episodeID: String?, accountId: Int64,
    itemRowId: Int64, episodeRowId: Int64?
  ) async -> PreparedPlayback? {
    // Local resume: the requested item is already this device's active offline session.
    // Idempotent, with no fresh session and no network, like the online resume below but
    // recovered from the database rather than the in-memory cache. There is nothing server-side
    // to reconcile a local session against, so its presence on relaunch is the recovery.
    if case .local(let material) = resolution,
      let activeLocal = try? await sessionStore.fetchActiveOfflineSessionAsync(accountId: accountId),
      activeLocal.itemId == itemRowId,
      activeLocal.podcastEpisodeId == episodeRowId,
      let activeLocalId = activeLocal.id
    {
      let prepared = PreparedPlayback(
        itemID: itemID, episodeID: episodeID, startPosition: activeLocal.globalPosition,
        duration: material.duration, tracks: material.tracks, chapters: material.chapters,
        source: .local)
      preparedBySessionID[activeLocalId] = prepared
      return prepared
    }

    // Online resume: the requested item is already this device's locally-active, cleanly-open
    // online session. Idempotent, no second `/play`.
    if case .streaming = resolution,
      let existing = try? await sessionStore.fetchActiveSessionAsync(accountId: accountId),
      existing.itemId == itemRowId,
      existing.podcastEpisodeId == episodeRowId,
      existing.closePending == false,
      let existingId = existing.id,
      let cached = preparedBySessionID[existingId]
    {
      return cached
    }
    return nil
  }

  /// The ordinary online `/play` flow. The resume and switch-freeze prelude lives in
  /// `performStart`, shared with the local path.
  private func performOnlineStart(
    itemID: String, episodeID: String?, accountRecord: AccountRecord, accountId: Int64, account: TokenAccount,
    itemRowId: Int64, episodeRowId: Int64?
  ) async throws -> PreparedPlayback {
    let options = StartPlaybackSessionOptions(
      deviceID: accountRecord.clientUUID,
      clientVersion: deviceMetadata.clientVersion,
      manufacturer: deviceMetadata.manufacturer,
      model: deviceMetadata.model,
      clientName: deviceMetadata.clientName,
      deviceName: deviceMetadata.deviceName,
      // Always direct play. Left unset, the server transcodes (`playMethod: 2`) to a single
      // `/hls/{sessionId}/output.m3u8` track only a retrying, socket-listening hls.js client can
      // consume: `HlsRouter` answers `404` for every segment ffmpeg has not written (including all
      // before the session's start position) and recovers via a `stream_reset` socket event.
      // `AVPlayer` neither retries a `404` nor speaks that protocol, so it fails the item at once.
      // Direct play is also the one-track-per-file shape the engine was measured on
      // (ARCHITECTURE.md); it needs the Bearer header on every track URL (`streamAuthorization`).
      forceDirectPlay: true
    )

    // Never opened: a `/play` failure here has nothing local to compensate for.
    let playbackSession = try await client.startPlaybackSession(
      account: account, itemID: itemID, episodeID: episodeID, options: options)

    // `forceDirectPlay` is a request, not a guarantee. A server that transcodes anyway returns a
    // playlist `AVPlayer` cannot consume, and the failure looks like a broken item rather than an
    // unsupported one. Check the shape here, where the just-opened server session can still be
    // compensated, rather than at the engine. Nothing local exists yet beyond `/play`.
    if Self.isUnusablePlaybackShape(playbackSession) {
      _ = try? await client.closePlaybackSession(account: account, sessionID: playbackSession.id)
      throw PlaybackCoordinatorError.unusableStream
    }

    // Minted after `/play` because that call runs the account's single-flight refresh when the
    // access token has expired, so stamping afterwards carries the token that authorised this
    // session rather than the one that failed.
    let streamAuthorization: PlaybackStreamAuthorization
    do {
      streamAuthorization = try await client.makePlaybackStreamAuthorization(account: account)
    } catch {
      _ = try? await client.closePlaybackSession(account: account, sessionID: playbackSession.id)
      throw error
    }

    // Persist the session id as soon as `/play` returns 200, before any further preparation, so
    // a crash on the next line still leaves a recoverable session id.
    let startedAt = clock.now()
    let started: PlaybackSessionRecord
    do {
      started = try await sessionStore.startSessionAsync(
        accountId: accountId,
        clientSessionId: generateClientSessionID(),
        itemId: itemRowId,
        podcastEpisodeId: episodeRowId,
        duration: playbackSession.duration,
        startedAt: startedAt
      )
    } catch {
      _ = try? await client.closePlaybackSession(account: account, sessionID: playbackSession.id)
      throw error
    }
    guard let sessionId = started.id,
      let confirmed = try? await sessionStore.setServerSessionIdAsync(
        sessionId: sessionId, serverSessionId: playbackSession.id)
    else {
      _ = try? await client.closePlaybackSession(account: account, sessionID: playbackSession.id)
      throw PlaybackCoordinatorError.persistenceFailed
    }

    let startPosition = await resolveStartPosition(
      account: account,
      accountId: accountId,
      itemID: itemID,
      episodeID: episodeID,
      itemRowId: itemRowId,
      episodeRowId: episodeRowId,
      incomingCurrentTime: playbackSession.currentTime ?? 0,
      duration: playbackSession.duration
    )

    // Stricter than ABSApi: a track it considered usable (a resolved stream) can still be
    // unusable for PlayerCore's global-timeline placement if its index, offset or duration never
    // arrived. Zero surviving tracks is malformed here even though `/play` succeeded.
    let tracks = playbackSession.audioTracks.compactMap(PreparedPlaybackTrack.init(track:))
    guard tracks.isEmpty == false else {
      let closeTick = PlaybackSessionClose(
        globalPosition: startPosition, deltaSecondsSinceLastSend: 0,
        localSequence: confirmed.lastLocalSequence, now: clock.now())
      _ = try? await sessionStore.closeAsync(sessionId: sessionId, tick: closeTick)
      await performFinalizationDrainRequest()
      throw PlaybackCoordinatorError.unusableStream
    }

    let chapters = playbackSession.chapters.map(PreparedPlaybackChapter.init(chapter:))
    let prepared = PreparedPlayback(
      itemID: itemID,
      episodeID: episodeID,
      startPosition: startPosition,
      duration: playbackSession.duration,
      tracks: tracks,
      chapters: chapters,
      streamAuthorization: streamAuthorization
    )
    preparedBySessionID[sessionId] = prepared
    return prepared
  }

  /// Whether a `/play` response is a shape this client cannot play.
  ///
  /// `playMethod` is the primary signal: `0` is DIRECTPLAY and `2` is TRANSCODE, confirmed against
  /// live servers. Any non-zero value is refused (DIRECTSTREAM and LOCAL
  /// are not requested or supported). The track shape is an independent check for when
  /// `playMethod` did not decode: a transcode session's single `/hls/{sessionId}/output.m3u8`
  /// track passes the stream resolver (same-origin) but the engine cannot use it.
  static func isUnusablePlaybackShape(_ session: PlaybackSession) -> Bool {
    if let playMethod = session.playMethod, playMethod != 0 { return true }
    return session.audioTracks.contains { track in
      let path = track.stream.url.path.lowercased()
      return path.hasSuffix(".m3u8") || path.contains("/hls/")
    }
  }

  /// `ProgressMergePolicy.resolve`, wired as the library pull does (`progressOutcome` in
  /// SyncEngine.swift): an unacknowledged local write outranks a `/play` response's `currentTime`,
  /// and a near-zero incoming position may not clobber substantial local progress. `/play` carries
  /// neither `isFinished` nor a server-update timestamp, so `isFinished` passes through from the
  /// local row and `serverUpdatedAt` is `nil`; the zero-position guard is the operative protection.
  ///
  /// `/play` also answers zero when another device reset the item by deleting its server row, and
  /// keeping local would let this session's sync recreate the row at the old position. So when the
  /// guard fires over a row this device observed, one `GET` checks the row still exists: proof of
  /// a reset starts at zero; anything else keeps local and records the conflict.
  private func resolveStartPosition(
    account: TokenAccount, accountId: Int64, itemID: String, episodeID: String?,
    itemRowId: Int64, episodeRowId: Int64?,
    incomingCurrentTime: Double, duration: Double?
  ) async -> Double {
    let identity = Self.progressIdentity(
      itemRowId: itemRowId, episodeRowId: episodeRowId)
    guard
      let local = try? await mediaProgressDAO.fetchCurrentAsync(
        accountId: accountId, identity: identity)
    else {
      return incomingCurrentTime
    }
    let hasUnacked =
      (try? await mediaProgressDAO.hasUnacknowledgedLocalOperationAsync(
        accountId: accountId, identity: identity)) ?? false
    let currentState = ProgressMergePolicy.CurrentState(
      currentTime: local.currentTime,
      isFinished: local.isFinished,
      serverUpdatedAt: local.serverUpdatedAt,
      localSequence: local.localSequence,
      originKey: local.originKey,
      hasUnacknowledgedLocalOperation: hasUnacked
    )
    let incoming = ProgressMergePolicy.IncomingObservation(
      currentTime: incomingCurrentTime,
      isFinished: local.isFinished,
      serverUpdatedAt: nil,
      originKey: ProgressMergePolicy.serverOriginKey
    )

    switch progressMerge.resolve(current: currentState, incoming: incoming, duration: duration) {
    case .applyServer:
      _ = try? await mediaProgressDAO.applyServerResolutionAsync(
        accountId: accountId, identity: identity,
        currentTime: incomingCurrentTime,
        isFinished: local.isFinished, serverUpdatedAt: nil)
      return incomingCurrentTime
    case .needsResolution:
      if await serverRowWasReset(
        account: account, itemID: itemID, episodeID: episodeID, local: local)
      {
        // The row id and its observed stamps stay as they were, so the next pull still sees the
        // reset and reconciles the fields this start does not own.
        _ = try? await mediaProgressDAO.applyServerResolutionAsync(
          accountId: accountId, identity: identity,
          currentTime: incomingCurrentTime,
          isFinished: false, serverUpdatedAt: local.serverUpdatedAt)
        return incomingCurrentTime
      }
      _ = try? await mediaProgressDAO.recordConflictAsync(
        accountId: accountId, identity: identity, serverCurrentTime: incomingCurrentTime,
        serverIsFinished: local.isFinished, serverUpdatedAt: nil, detectedAt: clock.now())
      return local.currentTime
    case .keepLocal, .rejectStale:
      return local.currentTime
    }
  }

  /// A single-row read is complete for its identity, so a missing row is as good as an absent one
  /// in a full snapshot. A failed or slow read proves nothing: the start waits at most
  /// `resetCheckTimeout` for it.
  private func serverRowWasReset(
    account: TokenAccount, itemID: String, episodeID: String?, local: MediaProgressRecord
  ) async -> Bool {
    guard local.serverProgressId != nil else { return false }
    let client = client
    let timeout = resetCheckTimeout
    let fetched: MediaProgress?? = await withTaskGroup(of: MediaProgress??.self) { group in
      group.addTask {
        // Not `try?`: it would flatten a failed read into the missing row that is evidence.
        do {
          return .some(
            try await client.fetchMediaProgress(
              account: account, libraryItemID: itemID, episodeID: episodeID))
        } catch {
          return .none
        }
      }
      group.addTask {
        try? await Task.sleep(for: .seconds(timeout))
        return .none
      }
      let first = await group.next() ?? .none
      group.cancelAll()
      return first
    }
    guard let row = fetched else { return false }
    return ProgressResetEvidence.isEvidenced(
      storedProgressID: local.serverProgressId,
      storedServerUpdatedAt: local.serverProgressUpdatedAt,
      observedRowIDs: row.map { [$0.serverProgressID] } ?? [],
      winnerStartedAt: row?.startedAt,
      snapshotIsComplete: true)
  }
}

extension PreparedPlaybackTrack {
  /// `nil` when `index`/`startOffset`/`duration` did not survive ABSApi's own (looser) decode.
  /// Unusable for PlayerCore's global-timeline placement even though the stream resolved.
  fileprivate init?(track: PlaybackSessionAudioTrack) {
    guard let index = track.index, let startOffset = track.startOffset, let duration = track.duration else {
      return nil
    }
    self.init(
      index: index, startOffset: startOffset, duration: duration, url: track.stream.url,
      mimeType: track.mimeType, title: track.title)
  }
}

extension PreparedPlaybackChapter {
  fileprivate init(chapter: PlaybackChapter) {
    self.init(id: chapter.id, start: chapter.start, end: chapter.end, title: chapter.title)
  }
}
