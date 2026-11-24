import ABSApi
import Foundation
import Persistence

/// Why a traversal was requested, ordered by how strongly it must be honoured. A trigger that
/// arrives while a run is in flight is coalesced into that run's follow-up, and the strongest
/// reason among the joiners wins, so an explicit pull or a committed inclusion is not demoted to
/// an anonymous repeat because it landed during a foreground pass.
enum RefreshReason: String, Sendable, Comparable {
  case foreground
  case librarySelectionDiscovery
  case explicit
  case librarySelection

  /// Discovery wants the library list; every other trigger wants the catalogue too.
  var scope: RefreshScope {
    self == .librarySelectionDiscovery ? .librariesOnly : .librariesAndItems
  }

  private var precedence: Int {
    switch self {
    case .foreground: 0
    case .librarySelectionDiscovery: 1
    case .explicit: 2
    case .librarySelection: 3
    }
  }

  static func < (lhs: Self, rhs: Self) -> Bool { lhs.precedence < rhs.precedence }
}

/// How much of a refresh a trigger actually wants.
///
/// `LibraryDiscoveryRefreshResult` promises only a reconciled accessible-library list, so
/// discovery skips the item pages: the Settings library screen reads `library` alone.
enum RefreshScope: Sendable {
  /// List request, reconciliation, and library-removal inference only.
  case librariesOnly
  /// The above, then every included library's item pages and the ancillary passes that need them.
  case librariesAndItems
}

extension SyncEngine {
  /// Explicit pull-to-refresh (SyncCoordinating).
  public func refresh() async {
    _ = await requestRefresh(reason: .explicit)
    await triggerOrdinaryOutboxDrain()
    await triggerLocalSessionUploadDrain()
  }

  /// The Settings library-selection surface needs a truthful discovery outcome while this actor
  /// stays the only owner of API work. A request that joins an existing run is reported as
  /// pending, not as a completed reconciliation.
  public func refreshLibraryDiscovery() async -> LibraryDiscoveryRefreshResult {
    await requestRefresh(reason: .librarySelectionDiscovery)
  }

  /// Selection writes call this only after committing an inclusion. A disabling write needs no
  /// refresh; `pullLibrary` and the ancillary hand-offs re-read the committed flags themselves.
  public func librarySelectionDidIncludeLibrary() async {
    _ = await requestRefresh(reason: .librarySelection)
  }

  /// Fires the injected `localSessionUploadDrain` closure, if any. The closure's drainer owns
  /// coalescing (its in-flight flag), so calling this repeatedly from launch, foreground and
  /// refresh in a tight window is safe.
  func triggerLocalSessionUploadDrain() async {
    guard isShutdown == false, let localSessionUploadDrain else { return }
    await localSessionUploadDrain()
  }

  /// The playback boundary owns the shared ordinary-drain request path. Its immediate trigger
  /// forwards to the same `OutboxDrainer` used by playback cadence, and is a no-op when no
  /// playback boundary is configured.
  func triggerOrdinaryOutboxDrain() async {
    guard isShutdown == false else { return }
    await playback?.notifyImmediateSyncTrigger(.catchUp)
  }

  /// The `AppLifecycle` subscription fans out to foreground refresh and playback lifecycle
  /// policy. A `.background` transition with no `playback` boundary configured is a no-op.
  func handleLifecycleTransition(_ transition: AppLifecycleTransition) async {
    guard isShutdown == false else { return }
    switch transition {
    case .foreground:
      #if PERF_INVESTIGATION
        // Diagnostic-only: keeps lifecycle playback/upload drains while isolating the library
        // traversal started by this foreground trigger.
        if ProcessInfo.processInfo.arguments.contains("-perf-no-foreground-library-refresh") == false {
          _ = await requestRefresh(reason: .foreground)
        }
      #else
        _ = await requestRefresh(reason: .foreground)
      #endif
      await triggerOrdinaryOutboxDrain()
      await triggerLocalSessionUploadDrain()
    case .background:
      guard let playback else { return }
      await appLifecycle.runBoundedBackgroundTask {
        await playback.handleAppBackgrounded()
      }
    }
  }

  /// A trigger during an active traversal records one follow-up instead of vanishing behind the
  /// single-flight guard. No suspension points between consuming the pending bit and rechecking
  /// it, so two callers cannot claim the same follow-up.
  ///
  /// The run belongs to the engine so `shutdown()` can cancel and await it. The starting caller
  /// still awaits it and cancelling that caller cancels the run; a joining caller returns
  /// `.pending` at once.
  private func requestRefresh(reason: RefreshReason) async -> LibraryDiscoveryRefreshResult {
    guard isShutdown == false else { return .unavailable }
    guard currentRefresh == nil else {
      pendingRefreshReason = pendingRefreshReason.map { Swift.max($0, reason) } ?? reason
      return .pending
    }
    let run = Task { await self.runRefreshes(startingWith: reason) }
    currentRefresh = run
    return await withTaskCancellationHandler {
      await run.value
    } onCancel: {
      run.cancel()
    }
  }

  private func runRefreshes(startingWith reason: RefreshReason) async -> LibraryDiscoveryRefreshResult {
    defer {
      currentRefresh = nil
      pendingRefreshReason = nil
    }

    var runReason = reason.rawValue
    var runScope = reason.scope
    var runIsForegroundInitiated = reason == .foreground
    var outcome: LibraryDiscoveryRefreshResult = .unavailable
    while true {
      pendingRefreshReason = nil
      outcome = await performRefresh(
        reason: runReason, scope: runScope, honorsMinimumInterval: runIsForegroundInitiated)
      guard isTraversalStopped == false, let pending = pendingRefreshReason else { break }

      // A foreground request arriving mid-traversal wants what that traversal is fetching;
      // replaying it would walk the catalogue twice for seconds-old data. An
      // `.active -> .inactive -> .active` bounce delivers `.foreground` twice, and the launch pull
      // races the scene's first `.active`: one intent arriving twice.
      //
      // So the traversal it joined satisfies it (staleness bounded by that run). Only a successful
      // run counts: an unavailable or libraries-only run fetched no pages, so the request is
      // replayed under its own reason.
      let joinedRunSatisfiesIt =
        pending == .foreground && runScope == .librariesAndItems && outcome == .reconciled
      if joinedRunSatisfiesIt { break }

      runReason = pending.rawValue
      runScope = pending.scope
      runIsForegroundInitiated = pending == .foreground
    }
    return outcome
  }

  private func performRefresh(
    reason: String, scope: RefreshScope, honorsMinimumInterval: Bool
  ) async -> LibraryDiscoveryRefreshResult {
    guard let accountRecord = try? await accountDAO.fetchAsync(), let accountId = accountRecord.id else {
      // No signed-in account yet, so nothing to pull.
      return .unavailable
    }
    guard let account = try? tokenAccount(for: accountRecord) else { return .unavailable }
    // An engine retained past its account must not touch the next account's rows: the reap below
    // would mark that account's live traversal incomplete. Its client refuses the account anyway.
    if let boundAccount = client.boundAccount, boundAccount != account { return .unavailable }

    // `runIfIdle` guarantees no run this process started is still open, so anything still marked
    // running was abandoned by a previous process and must be settled before it is read as a live
    // traversal for the rest of this database's life.
    _ = try? await syncRunDAO.reapAbandonedRunsAsync(accountId: accountId, at: clock.now())

    if let allowedAt = nextLibraryListAttemptAllowedAt, clock.now() < allowedAt {
      return .unavailable
    }

    guard
      let libraries = await refreshLibraries(
        account: account, accountId: accountId, reason: reason, scope: scope,
        honorsMinimumInterval: honorsMinimumInterval)
    else {
      return .unavailable
    }
    // Every pass below follows up on item rows the traversal just wrote. A libraries-only pass
    // wrote none.
    guard scope == .librariesAndItems else { return .reconciled }
    // Each engine-owned ancillary hand-off gets a fresh selection read. Its worker is
    // independently owned; this only stops another pass starting after the last inclusion was
    // removed or the engine shut down mid-walk.
    if await mayStartHandOff(accountId: accountId) {
      await authorSeriesFilterDataRefresh?()
    }
    if await mayStartHandOff(accountId: accountId) {
      await libraryCollectionRefresh?()
    }
    if await mayStartHandOff(accountId: accountId) {
      await refreshPodcastSurfaces(account: account, accountId: accountId, libraries: libraries)
    }
    // The backfill needs the item rows `refreshLibraries` just wrote. It runs after the podcast
    // shelf because its four awaited batch requests are background enrichment, while the shelf
    // feeds a user-visible Home row.
    if await mayStartHandOff(accountId: accountId) {
      await metadataBackfill?.backfillOnePage()
    }
    return .reconciled
  }

  private func refreshLibraries(
    account: TokenAccount, accountId: Int64, reason: String, scope: RefreshScope,
    honorsMinimumInterval: Bool
  ) async -> [Library]? {
    let libraries: [Library]
    let libraryListDiagnostics = DecodeDiagnostics()
    do {
      libraries = try await client.listLibraries(
        account: account, diagnostics: libraryListDiagnostics)
      libraryListBackoff = nil
      nextLibraryListAttemptAllowedAt = nil
    } catch {
      let scheduled = scheduleBackoff(current: libraryListBackoff, at: clock.now())
      libraryListBackoff = scheduled.policy
      nextLibraryListAttemptAllowedAt = scheduled.nextAttemptAllowedAt
      return nil
    }

    // `includingRemoved: true` is the only read that wants tombstoned libraries. Item removal
    // under a missing library follows the usual two-pass deletion inference: pass one
    // soft-deletes the items, pass two reaps them. The default list hides tombstones, so the
    // library would never be revisited and its items would stay soft-deleted.
    let localLibraries =
      (try? await libraryDAO.fetchAccessibleAsync(accountId: accountId, includingRemoved: true)) ?? []
    let serverLibraryIds = Set(libraries.map(\.id))

    // All selection-sensitive row changes share this one commit: existing flags survive a
    // descriptor refresh/revival, while a newly visible library follows the account policy.
    guard
      let reconciliation = try? await LibraryReconciliationStore(
        database: database, accountID: accountId
      ).reconcile(
        libraries.map {
          LibraryReconciliationDescriptor(
            serverLibraryID: $0.id, name: $0.name, mediaType: $0.mediaType ?? "book",
            onlyShowLaterBooksInContinueSeries: $0.onlyShowLaterBooksInContinueSeries)
        })
    else { return nil }

    // Explicit library removal: a locally known library the server's list no longer mentions
    // follows the same two-pass/tombstone rule as a missing item. A lossily decoded list is not
    // evidence of removal (a dropped element looks like an absent one), so any decode diagnostic
    // disqualifies this pass from inferring removal.
    if libraryListDiagnostics.entries.isEmpty {
      for local in localLibraries where serverLibraryIds.contains(local.serverLibraryId) == false {
        await handleMissingLibrary(local, accountId: accountId)
      }
    } else {
      await diagnostics.record(
        DiagnosticsEvent(
          category: .decodeDiagnostic,
          statusClass: .success,
          durationMilliseconds: 0,
          endpointTemplate: EndpointTemplate("/api/libraries")
        ),
        accountId: accountId
      )
    }

    let includedServerLibraryIDs = Set(reconciliation.liveIncludedServerLibraryIDs)
    let includedRows = (try? await libraryDAO.fetchIncludedAsync(accountId: accountId)) ?? []
    let includedRowIDsByServerID = Dictionary(
      uniqueKeysWithValues: includedRows.compactMap { row in row.id.map { (row.serverLibraryId, $0) } })
    let includedLibraries = libraries.filter {
      includedServerLibraryIDs.contains($0.id) && includedRowIDsByServerID[$0.id] != nil
    }

    // Discovery/removal inference above stays account-wide, but with no included library there is
    // no profile request, catalogue page, episode hydration or ancillary work.
    guard includedLibraries.isEmpty == false else { return [] }
    // Discovery stops here: reconciliation and library-removal inference are all it promises,
    // and `/api/me` and the page walk below serve the catalogue.
    guard scope == .librariesAndItems else { return includedLibraries }
    // Fetched once per refresh, not per library, and matched by libraryItemID during each
    // library's page application below.
    let progressByIdentity = await fetchProgressByIdentity(account: account, accountId: accountId)

    // A library `pullLibrary` declines (failure backoff or the interval gate) never reaches the
    // per-page progress apply, so its row id is collected here and served from local rows below.
    var skippedLibraryRowIds: [Int64] = []
    for library in includedLibraries {
      guard let libraryRowId = includedRowIDsByServerID[library.id] else { continue }
      let traversed = await pullLibrary(
        account: account, library: library, libraryRowId: libraryRowId, accountId: accountId,
        reason: reason, progress: progressByIdentity,
        honorsMinimumInterval: honorsMinimumInterval)
      if traversed == false { skippedLibraryRowIds.append(libraryRowId) }
    }

    await applyProgressToExistingRows(
      accountId: accountId, libraryRowIds: skippedLibraryRowIds, progress: progressByIdentity)
    await applyResetEvidenceToAbsentRows(accountId: accountId, progress: progressByIdentity)

    // The episode-keyed half of the `/api/me` rows: a minified page carries no episodes, so the
    // loop had no local row to attach it to. Runs after the traversal because it needs the item
    // rows the pages wrote. A complete snapshot with no episode rows still runs, since that is how
    // a reset of the last part-heard episode arrives.
    if let podcastProgressHydration,
      progressByIdentity.episodeByShowID.isEmpty == false || progressByIdentity.isComplete,
      await mayStartHandOff(accountId: accountId)
    {
      await podcastProgressHydration.hydrate(
        accountId: accountId, progress: progressByIdentity.rows,
        progressIsComplete: progressByIdentity.isComplete)
    }

    return includedLibraries
  }

  private func refreshPodcastSurfaces(
    account: TokenAccount, accountId: Int64, libraries: [Library]
  ) async {
    // Home's "new this week" row comes from the server's newest-episodes shelf, not from
    // inferring recency out of a locally expanded catalogue. One request per podcast library is
    // cheap enough to await inline, so the row is current when the refresh reports done.
    // Expanding a show's full episode list stays with `PodcastRefreshCoordinator`.
    let podcastLibraryIDs = libraries.filter { $0.mediaType == "podcast" }.map(\.id)
    if let recentEpisodes, podcastLibraryIDs.isEmpty == false {
      let now = clock.now()
      let eligiblePodcastLibraryIDs = podcastLibraryIDs.filter { libraryID in
        guard let allowedAt = nextPodcastShelfAttemptAllowedAtByLibraryID[libraryID] else {
          return true
        }
        return now >= allowedAt
      }
      guard eligiblePodcastLibraryIDs.isEmpty == false else { return }

      var committedShelf = false
      for libraryID in eligiblePodcastLibraryIDs {
        // `RecentEpisodeRefreshCoordinator` owns the individual shelf request and persistence.
        // Calling it one library at a time lets the engine re-read selection before each request
        // without changing the all-included request order.
        guard await isLibraryIncluded(accountId: accountId, serverLibraryID: libraryID) else { continue }
        let result: RecentEpisodeRefreshResult
        do {
          result = try await recentEpisodes.refresh(
            account: account, accountId: accountId, podcastLibraryIDs: [libraryID])
        } catch {
          continue
        }
        committedShelf = committedShelf || result.commitOutcome == .committed
        if result.failedLibraryIDs.contains(libraryID) {
          let scheduled = scheduleBackoff(
            current: podcastShelfBackoffByLibraryID[libraryID], at: clock.now())
          podcastShelfBackoffByLibraryID[libraryID] = scheduled.policy
          nextPodcastShelfAttemptAllowedAtByLibraryID[libraryID] = scheduled.nextAttemptAllowedAt
        } else {
          podcastShelfBackoffByLibraryID.removeValue(forKey: libraryID)
          nextPodcastShelfAttemptAllowedAtByLibraryID.removeValue(forKey: libraryID)
        }
      }
      guard committedShelf else { return }
      // After a recent-episodes shelf commit: one coordinator pass, then reap. A thrown commit
      // returns above, so a failed or rolled-back episode write never triggers a pass.
      if await mayStartHandOff(accountId: accountId) {
        await podcastAutoDownload?.run()
      }
      if await mayStartHandOff(accountId: accountId) {
        await podcastAutoDownloadReaper?.reap()
      }
    }
  }

  /// Checked before every ancillary pass a traversal hands off to: the pass needs an included
  /// library, and a stopped traversal starts nothing new.
  private func mayStartHandOff(accountId: Int64) async -> Bool {
    guard isTraversalStopped == false else { return false }
    return ((try? await libraryDAO.fetchIncludedAsync(accountId: accountId)) ?? []).isEmpty == false
  }

  func isLibraryIncluded(accountId: Int64, serverLibraryID: String) async -> Bool {
    (try? await libraryDAO.fetchOneIncludedAsync(
      accountId: accountId, serverLibraryId: serverLibraryID)) != nil
  }
}
