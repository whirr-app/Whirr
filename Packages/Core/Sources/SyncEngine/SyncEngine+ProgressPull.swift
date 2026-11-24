import ABSApi
import Foundation
import Persistence

extension SyncEngine {
  func fetchProgressByIdentity(account: TokenAccount, accountId: Int64) async -> ProgressByIdentity {
    // The minified item-list DTO carries no embedded `userMediaProgress`, so pull it once per run
    // via `/api/me` and match by libraryItemID during page application. The item-level
    // last-row-wins map is kept, and episode identity is retained for selected-show consumers.
    if let allowedAt = nextProgressAttemptAllowedAt, clock.now() < allowedAt {
      return ProgressByIdentity()
    }
    let bookmarkStore = AudioBookmarkStore(database: database)
    // Read before the fetch, and again inside the apply: a bookmark intent acknowledged while the
    // request is in flight has left the second read but may be missing from this snapshot. If this
    // read fails, the bookmarks are not applied this run rather than applied unprotected.
    let protectedBookmarks = try? await bookmarkStore.unacknowledgedKeys(accountId: accountId)
    do {
      let snapshot = try await client.fetchUserProgressSnapshot(account: account)
      try? await HiddenContinueSeriesStore(database: database).replace(
        accountId: accountId, serverSeriesIDs: snapshot.hiddenSeriesIDs)
      if let protectedBookmarks {
        try? await bookmarkStore.applyServerBookmarks(
          accountId: accountId,
          snapshot.bookmarks.map {
            AudioBookmark(
              serverItemID: $0.libraryItemID, time: $0.time, title: $0.title, createdAt: $0.createdAt)
          },
          isComplete: snapshot.bookmarksAreComplete,
          protecting: protectedBookmarks)
      }
      progressBackoff = nil
      nextProgressAttemptAllowedAt = nil
      return ProgressByIdentity(rows: snapshot.progress, isComplete: snapshot.isComplete)
    } catch {
      let scheduled = scheduleBackoff(current: progressBackoff, at: clock.now())
      progressBackoff = scheduled.policy
      nextProgressAttemptAllowedAt = scheduled.nextAttemptAllowedAt
      return ProgressByIdentity()
    }
  }

  /// Applies `/api/me` item progress to rows that already exist, for libraries this refresh did
  /// not traverse.
  ///
  /// Item-keyed progress is otherwise applied only inside the page walk
  /// (`SyncEngine+LibraryPull.swift`), so a library skipped by its failure backoff or interval gate
  /// would have its progress fetched and discarded. Same policy and commit, resolved against local
  /// rows. Every decision comes from `progressOutcome`, including the unacknowledged-local-write
  /// and live-session protections.
  func applyProgressToExistingRows(
    accountId: Int64, libraryRowIds: [Int64], progress snapshot: ProgressByIdentity
  ) async {
    let progressByItemID = snapshot.itemByID
    guard libraryRowIds.isEmpty == false, progressByItemID.isEmpty == false else { return }

    // Selection is re-read here, not carried in. The caller chose these row ids before `/api/me`
    // and the page walks, and `LibrarySelectionStore` can commit an exclusion anywhere in that
    // window with no engine coordination, so an excluded library's rows would otherwise receive
    // account-wide progress. Same re-check the page path makes before applying a page.
    let includedRowIDs = Set(
      ((try? await libraryDAO.fetchIncludedAsync(accountId: accountId)) ?? []).compactMap(\.id))
    let applicableLibraryRowIds = libraryRowIds.filter { includedRowIDs.contains($0) }
    guard applicableLibraryRowIds.isEmpty == false else { return }

    guard
      let targets = try? await itemDAO.progressTargetsAsync(
        accountId: accountId, libraryIds: applicableLibraryRowIds,
        serverItemIds: Array(progressByItemID.keys))
    else { return }

    var resolutions: [MediaProgressDAO.PulledCompositeResolution] = []
    var conflicts: [MediaProgressDAO.PulledCompositeConflict] = []
    for target in targets {
      guard let progress = progressByItemID[target.serverItemId] else { continue }
      guard
        let outcome = await progressOutcome(
          accountId: accountId, itemRowId: target.itemRowId, progress: progress,
          duration: target.durationSeconds,
          observedRowIDs: snapshot.itemRowIDs[target.serverItemId] ?? [],
          snapshotIsComplete: snapshot.isComplete)
      else { continue }
      if let resolution = outcome.resolution { resolutions.append(resolution) }
      if let conflict = outcome.conflict { conflicts.append(conflict) }
    }

    // One commit for all skipped libraries: each commit re-runs every open `ValueObservation`.
    try? await mediaProgressDAO.applyPulledCompositeProgressAsync(
      accountId: accountId, resolutions: resolutions, conflicts: conflicts)
  }

  /// Applies reset evidence to identities a complete snapshot omits: rows this device observed on
  /// the server that no longer exist there.
  ///
  /// The page walk and `applyProgressToExistingRows` visit only identities the snapshot holds. This
  /// synthesizes the server's post-reset state (zero, unfinished, visible) for `progressOutcome`,
  /// so its protections (unsent writes, live and offline sessions) still outrank it.
  func applyResetEvidenceToAbsentRows(accountId: Int64, progress snapshot: ProgressByIdentity) async {
    guard snapshot.isComplete else { return }
    // Selection can change mid-run, as in `applyProgressToExistingRows`.
    let includedRowIDs = ((try? await libraryDAO.fetchIncludedAsync(accountId: accountId)) ?? [])
      .compactMap(\.id)
    guard
      let observed = try? await mediaProgressDAO.observedItemProgressAsync(
        accountId: accountId, libraryIds: includedRowIDs)
    else { return }

    var resolutions: [MediaProgressDAO.PulledCompositeResolution] = []
    var conflicts: [MediaProgressDAO.PulledCompositeConflict] = []
    for row in observed where snapshot.itemRowIDs[row.serverItemId] == nil {
      let absent = MediaProgress(
        libraryItemID: row.serverItemId, episodeID: nil, mediaItemID: nil, mediaItemType: nil,
        duration: nil, progress: 0, currentTime: 0, isFinished: false,
        hideFromContinueListening: false, ebookLocation: nil,
        ebookProgress: row.hasEbookPosition ? 0 : nil, lastUpdate: nil, startedAt: nil,
        finishedAt: nil, serverProgressID: nil)
      guard
        let outcome = await progressOutcome(
          accountId: accountId, itemRowId: row.itemRowId, progress: absent,
          duration: row.durationSeconds, observedRowIDs: [], snapshotIsComplete: true)
      else { continue }
      if let resolution = outcome.resolution { resolutions.append(resolution) }
      if let conflict = outcome.conflict { conflicts.append(conflict) }
    }
    try? await mediaProgressDAO.applyPulledCompositeProgressAsync(
      accountId: accountId, resolutions: resolutions, conflicts: conflicts)
  }

  /// One item's pull outcome, decided but not yet written. `pullLibrary` collects a page's worth
  /// and commits them together.
  struct PulledProgressOutcome {
    let resolution: MediaProgressDAO.PulledCompositeResolution?
    let conflict: MediaProgressDAO.PulledCompositeConflict?

    init(
      resolution: MediaProgressDAO.PulledCompositeResolution? = nil,
      conflict: MediaProgressDAO.PulledCompositeConflict? = nil
    ) {
      self.resolution = resolution
      self.conflict = conflict
    }
  }

  /// - Parameters:
  ///   - observedRowIDs: every row id the snapshot holds for this identity. Empty only for the
  ///     zero observation `applyResetEvidenceToAbsentRows` synthesizes for an absent identity.
  func progressOutcome(
    accountId: Int64,
    itemRowId: Int64,
    progress: MediaProgress,
    duration: Double?,
    observedRowIDs: [String?],
    snapshotIsComplete: Bool
  ) async -> PulledProgressOutcome? {
    // A row with no position fields at all is dropped. An ebook-only row is a real observation
    // and must reach the composite policy below.
    guard progress.currentTime != nil || progress.ebookProgress != nil || progress.ebookLocation != nil
    else { return nil }

    let current: MediaProgressRecord?
    do {
      current = try await mediaProgressDAO.fetchCurrentAsync(
        accountId: accountId, identity: .item(itemId: itemRowId))
    } catch {
      return nil
    }

    let hasUnackedAudioPosition =
      (try? await mediaProgressDAO.hasUnacknowledgedLocalOperationAsync(
        accountId: accountId, identity: .item(itemId: itemRowId), field: .audioPosition)) ?? false
    let hasUnackedEbookPosition =
      (try? await mediaProgressDAO.hasUnacknowledgedLocalOperationAsync(
        accountId: accountId, identity: .item(itemId: itemRowId), field: .ebookPosition)) ?? false
    let hasUnackedFinish =
      (try? await mediaProgressDAO.hasUnacknowledgedLocalOperationAsync(
        accountId: accountId, identity: .item(itemId: itemRowId), field: .sharedFinish)) ?? false
    let hasUnackedVisibility =
      (try? await mediaProgressDAO.hasUnacknowledgedLocalOperationAsync(
        accountId: accountId, identity: .item(itemId: itemRowId),
        field: .continueListeningVisibility)) ?? false
    // A live session's own ticks are keyed under the session's entity
    // (`session:<clientSessionId>`), so the item-keyed check above cannot see them. This protects
    // a live playing position mid-session.
    let hasUnackedSession: Bool
    // An active local (offline) session for this item is also invisible to the item-keyed check:
    // its ticks create no outbox row, so it needs its own signal. While it is open nothing
    // server-side has seen its position (only the eventual `local-all` batch reports it), so a
    // foreground pull must not overwrite it.
    let hasActiveOfflineSession: Bool
    if let sessionStore {
      hasUnackedSession =
        (try? await sessionStore.hasUnacknowledgedSessionWriteAsync(
          accountId: accountId, itemId: itemRowId)) ?? false
      hasActiveOfflineSession =
        (try? await sessionStore.hasActiveOfflineSessionAsync(
          accountId: accountId, itemId: itemRowId)) ?? false
    } else {
      hasUnackedSession = false
      hasActiveOfflineSession = false
    }
    let hasUnackedAudio = hasUnackedAudioPosition || hasUnackedSession || hasActiveOfflineSession
    let hasUnackedFinishField = hasUnackedFinish || hasUnackedSession || hasActiveOfflineSession
    let currentState = ProgressMergePolicy.CurrentState(
      currentTime: current?.currentTime ?? 0,
      isFinished: current?.isFinished ?? false,
      serverUpdatedAt: current?.serverUpdatedAt,
      localSequence: current?.localSequence ?? 0,
      originKey: current?.originKey ?? ProgressMergePolicy.serverOriginKey,
      ebookProgress: current?.ebookProgress,
      readingPositionJSON: current?.readingPositionJSON,
      ebookLocation: current?.ebookLocation,
      hasUnacknowledgedAudioOperation: hasUnackedAudio,
      hasUnacknowledgedEbookOperation: hasUnackedEbookPosition,
      hasUnacknowledgedFinishOperation: hasUnackedFinishField
    )
    let incoming = ProgressMergePolicy.IncomingObservation(
      // The composite policy is scalar. A missing audio position is represented by the current
      // value for this decision call only; its audio result is forced to keep-local below so
      // Persistence never fabricates an audio write.
      currentTime: progress.currentTime ?? current?.currentTime ?? 0,
      isFinished: progress.isFinished,
      serverUpdatedAt: progress.lastUpdate,
      originKey: ProgressMergePolicy.serverOriginKey,
      signalsExplicitResetOrUnfinished: ProgressResetEvidence.isEvidenced(
        storedProgressID: current?.serverProgressId,
        storedServerUpdatedAt: current?.serverProgressUpdatedAt,
        observedRowIDs: observedRowIDs,
        winnerStartedAt: progress.startedAt,
        snapshotIsComplete: snapshotIsComplete),
      ebookProgress: progress.ebookProgress,
      ebookLocation: progress.ebookLocation
    )

    let policyDecision = progressMerge.resolveComposite(
      current: currentState, incoming: incoming, duration: duration)
    let hasEbookObservation = progress.ebookProgress != nil || progress.ebookLocation != nil
    // A previously unseen server row is seeded directly, including an untimestamped zero
    // position. The composite policy still receives the observation first, and a normal existing
    // row follows its full ordering/guard decisions.
    let audioDecision: ProgressMergePolicy.Decision =
      if progress.currentTime == nil {
        .keepLocal
      } else if current == nil && hasUnackedAudioPosition == false {
        .applyServer
      } else {
        policyDecision.audioPosition
      }
    let ebookDecision: ProgressMergePolicy.Decision =
      if hasEbookObservation == false {
        .keepLocal
      } else if current == nil && hasUnackedEbookPosition == false {
        .applyServer
      } else {
        policyDecision.ebookPosition
      }
    let sharedFinishDecision: ProgressMergePolicy.Decision =
      if current == nil && hasUnackedFinish == false {
        .applyServer
      } else {
        policyDecision.sharedFinish
      }
    let resolution: MediaProgressCompositeResolution = MediaProgressCompositeResolution(
      audioPosition: Self.mapResolution(audioDecision),
      ebookPosition: Self.mapResolution(ebookDecision),
      sharedFinish: Self.mapResolution(sharedFinishDecision),
      continueListeningVisibility: hasUnackedVisibility ? .keepLocal : .applyServer)
    let hasAppliedField =
      resolution.audioPosition == MediaProgressResolution.applyServer
      || resolution.ebookPosition == MediaProgressResolution.applyServer
      || resolution.sharedFinish == MediaProgressResolution.applyServer
      || resolution.continueListeningVisibility == MediaProgressResolution.applyServer
    let hasConflict =
      resolution.audioPosition == MediaProgressResolution.needsResolution
      || resolution.ebookPosition == MediaProgressResolution.needsResolution
      || resolution.sharedFinish == MediaProgressResolution.needsResolution

    guard hasAppliedField || hasConflict else { return nil }
    let pulledResolution =
      hasAppliedField
      ? MediaProgressDAO.PulledCompositeResolution(
        identity: .item(itemId: itemRowId),
        currentTime: progress.currentTime,
        isFinished: progress.isFinished,
        ebookProgress: progress.ebookProgress,
        ebookLocation: progress.ebookLocation,
        hideFromContinueListening: progress.hideFromContinueListening,
        serverUpdatedAt: progress.lastUpdate,
        serverProgressId: progress.serverProgressID,
        resolution: resolution)
      : nil
    let pulledConflict =
      hasConflict
      ? MediaProgressDAO.PulledCompositeConflict(
        identity: .item(itemId: itemRowId),
        // The legacy resolution-center row has one server position slot. An ebook-only conflict
        // has no server audio value, so retain the local audio value rather than letting a later
        // take-server action manufacture an audio reset.
        serverCurrentTime: progress.currentTime ?? current?.currentTime ?? 0,
        serverIsFinished: progress.isFinished,
        serverUpdatedAt: progress.lastUpdate,
        detectedAt: clock.now(),
        serverEbookProgress: resolution.ebookPosition == .needsResolution
          ? progress.ebookProgress : nil,
        serverEbookLocation: resolution.ebookPosition == .needsResolution
          ? progress.ebookLocation : nil)
      : nil
    return PulledProgressOutcome(resolution: pulledResolution, conflict: pulledConflict)
  }

  private static func mapResolution(
    _ decision: ProgressMergePolicy.Decision
  ) -> MediaProgressResolution {
    switch decision {
    case .applyServer: .applyServer
    case .keepLocal: .keepLocal
    case .needsResolution: .needsResolution
    case .rejectStale: .rejectStale
    }
  }
}
