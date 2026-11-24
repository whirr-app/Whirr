import ABSApi
import Foundation
import Persistence

extension SyncEngine {
  func handleMissingLibrary(_ local: LibraryRecord, accountId: Int64) async {
    guard let libraryRowId = local.id else { return }
    guard let generation = try? await syncRunDAO.nextGenerationAsync(accountId: accountId) else { return }
    let now = clock.now()
    guard
      let run = try? await syncRunDAO.startRunAsync(
        accountId: accountId,
        libraryId: libraryRowId,
        reason: "libraryRemoved",
        generation: generation,
        sortRequested: nil,
        startedAt: now
      ),
      let runId = run.id
    else { return }

    try? await syncRunDAO.finishAsync(
      runId: runId, state: .completed, completedAt: now, errorCategory: nil)
    _ = try? await syncRunDAO.inferDeletionsAsync(
      libraryId: libraryRowId, generation: generation)

    // Tombstone the library row itself, or `search(libraryIDs:query:limit:)` keeps fanning out to
    // a library the server no longer has (deleted or re-created under a new id) and 404s.
    //
    // Marked, never deleted: `library` cascades to `item` and `download`, so a delete would let
    // `DownloadIntegritySweep` reclaim files over an inference one response can reverse.
    // `refreshLibraries` clears the flag when the server lists the library again, keeping the
    // inclusion choice.
    var tombstoned = local
    tombstoned.softDeleted = true
    _ = try? await libraryDAO.upsertAsync(tombstoned)

    await recordSyncRunDiagnostics(accountId: accountId, statusClass: .success, durationMilliseconds: 0)
  }

  private enum RunOutcome {
    case completed
    case incomplete
    case unstablePagination
  }

  /// Walks one library's item pages, returning whether the walk actually ran.
  ///
  /// `false` means this library's item-keyed `/api/me` progress was never applied (the apply is
  /// inside the page loop), so the caller owes it `applyProgressToExistingRows`. Both declines
  /// below are invisible from the call site: the inclusion guard re-reads committed selection and
  /// the backoff gate is engine memory from a previous run. A stopped traversal declines too.
  @discardableResult
  func pullLibrary(
    account: TokenAccount,
    library: Library,
    libraryRowId: Int64,
    accountId: Int64,
    reason: String,
    progress snapshot: ProgressByIdentity,
    honorsMinimumInterval: Bool
  ) async -> Bool {
    guard isTraversalStopped == false else { return false }
    guard await isLibraryIncluded(accountId: accountId, serverLibraryID: library.id) else { return false }
    let startedAt = clock.now()
    if let allowed = nextAttemptAllowedAtByLibraryRowId[libraryRowId], startedAt < allowed {
      return false
    }
    // A minimum interval between completed traversals, for foreground-initiated refreshes only.
    // Pull-to-refresh, library selection and discovery are never gated here: the user asked.
    //
    // The source is engine memory, not `syncRun`: `handleMissingLibrary` writes a `.completed`
    // zero-page run ("libraryRemoved") that a `syncRun` gate would read as "recently traversed",
    // skipping the pass that revives a re-listed library's items.
    if honorsMinimumInterval, let lastCompleted = lastCompletedTraversalAtByLibraryRowId[libraryRowId],
      startedAt.timeIntervalSince(lastCompleted) < Self.minimumForegroundTraversalInterval
    {
      return false
    }

    guard let generation = try? await syncRunDAO.nextGenerationAsync(accountId: accountId) else {
      return false
    }
    guard
      let run = try? await syncRunDAO.startRunAsync(
        accountId: accountId,
        libraryId: libraryRowId,
        reason: reason,
        generation: generation,
        sortRequested: Self.requestedSort,
        startedAt: startedAt
      ),
      let runId = run.id
    else { return false }

    var planner = LibraryTraversalPlanner(pageSize: pageLimit)
    var action = planner.start()
    var runOutcome: RunOutcome = .incomplete
    var failureCategory: String?
    var decodeDiagnosticsHit = false

    pageLoop: while true {
      switch action {
      case .requestPage(let pageNumber):
        // Shutdown or run cancellation ends the walk here: the page already awaiting a response
        // is the last one, and the run ends `incomplete`.
        guard isTraversalStopped == false else { break pageLoop }
        // A selection write may have committed while the previous page was in flight. Only the
        // request already awaiting a response may follow it.
        guard await isLibraryIncluded(accountId: accountId, serverLibraryID: library.id) else {
          break pageLoop
        }
        let decodeDiagnostics = DecodeDiagnostics()
        let page: LibraryItemsPage
        do {
          page = try await client.listLibraryItems(
            account: account,
            library: library.id,
            page: pageNumber,
            limit: pageLimit,
            sort: Self.requestedSort,
            diagnostics: decodeDiagnostics
          )
        } catch {
          failureCategory = Self.errorCategory(for: error)
          runOutcome = .incomplete
          break pageLoop
        }
        if decodeDiagnostics.entries.isEmpty == false {
          decodeDiagnosticsHit = true
        }

        // Preserve `addedAt` when a page omits it (e.g. a trimmed/older server response shape).
        // Needs the existing row's value up front, which the pure `mapItem` cannot see.
        let existingMetadataById =
          (try? await itemDAO.preservedMetadataByServerItemIdAsync(
            libraryId: libraryRowId, serverItemIds: page.items.map(\.id))) ?? [:]
        var pulledItems: [ItemRecord] = []
        pulledItems.reserveCapacity(page.items.count)
        for summary in page.items {
          if let item = Self.mapItem(
            summary, library: library, accountId: accountId, libraryId: libraryRowId,
            existingMetadata: existingMetadataById[summary.id])
          {
            pulledItems.append(item)
          }
        }

        let savedItems: [ItemRecord]
        do {
          savedItems = try await syncRunDAO.applyPageAsync(
            runId: runId,
            accountId: accountId,
            libraryId: libraryRowId,
            generation: generation,
            items: pulledItems,
            pageNumber: pageNumber,
            fetchedAt: clock.now(),
            resultCategory: nil
          )
        } catch {
          failureCategory = "persistenceFailure"
          runOutcome = .incomplete
          break pageLoop
        }

        // Decide every item's outcome first (reads only), then commit the page in one transaction:
        // each commit re-runs every open `ValueObservation`, so per-item commits would cost a
        // full-library refetch and list diff each. `/api/me` is account-wide and the library may
        // have been excluded mid-flight, so skip its progress once the selection drops it.
        if await isLibraryIncluded(accountId: accountId, serverLibraryID: library.id) {
          var resolutions: [MediaProgressDAO.PulledCompositeResolution] = []
          var conflicts: [MediaProgressDAO.PulledCompositeConflict] = []
          for saved in savedItems {
            guard let itemRowId = saved.id, let progress = snapshot.itemByID[saved.serverItemId]
            else { continue }
            switch await progressOutcome(
              accountId: accountId, itemRowId: itemRowId, progress: progress,
              duration: saved.durationSeconds,
              observedRowIDs: snapshot.itemRowIDs[saved.serverItemId] ?? [],
              snapshotIsComplete: snapshot.isComplete)
            {
            case let outcome?:
              if let resolution = outcome.resolution { resolutions.append(resolution) }
              if let conflict = outcome.conflict { conflicts.append(conflict) }
            case nil: break
            }
          }
          try? await mediaProgressDAO.applyPulledCompositeProgressAsync(
            accountId: accountId, resolutions: resolutions, conflicts: conflicts)
        }

        action = planner.handle(
          LibraryTraversalPlanner.PageResponse(
            pageNumber: pageNumber, itemIds: page.items.map(\.id), reportedTotal: page.total))

      case .finish(let outcome):
        switch outcome {
        case .complete:
          runOutcome = .completed
        case .incomplete:
          runOutcome = .incomplete
        case .abort:
          runOutcome = .unstablePagination
        }
        break pageLoop
      }
    }

    let completedAt = clock.now()
    let runState: SyncRunState
    switch runOutcome {
    case .completed: runState = .completed
    case .incomplete: runState = .incomplete
    case .unstablePagination: runState = .unstablePagination
    }
    try? await syncRunDAO.finishAsync(
      runId: runId, state: runState, completedAt: completedAt, errorCategory: failureCategory)

    if runOutcome == .completed {
      // The traversal finished, so the run completes and backoff clears. A page that decoded
      // lossily was shorter than what the server sent, and an item dropped from it looks like one
      // the server deleted, so deletion inference waits for a clean pass.
      if decodeDiagnosticsHit == false {
        _ = try? await syncRunDAO.inferDeletionsAsync(
          libraryId: libraryRowId, generation: generation)
      }
      backoffByLibraryRowId.removeValue(forKey: libraryRowId)
      nextAttemptAllowedAtByLibraryRowId.removeValue(forKey: libraryRowId)
      // Recorded only on the completed branch: an incomplete or unstable run leaves deletion
      // inference unfinished and must not cause a later pass to be skipped.
      lastCompletedTraversalAtByLibraryRowId[libraryRowId] = completedAt
    } else {
      var backoff = backoffByLibraryRowId[libraryRowId] ?? ABSApi.BackoffPolicy()
      let delay = backoff.nextDelay(randomUnit: randomSource())
      backoffByLibraryRowId[libraryRowId] = backoff
      nextAttemptAllowedAtByLibraryRowId[libraryRowId] = completedAt.addingTimeInterval(delay)
    }

    await recordSyncRunDiagnostics(
      accountId: accountId,
      statusClass: failureCategory == nil ? .success : .transportError,
      durationMilliseconds: Self.durationMilliseconds(startedAt: startedAt, endedAt: completedAt)
    )
    if decodeDiagnosticsHit {
      await diagnostics.record(
        DiagnosticsEvent(
          category: .decodeDiagnostic,
          statusClass: .success,
          durationMilliseconds: 0,
          endpointTemplate: EndpointTemplate("/api/libraries/:id/items")
        ),
        accountId: accountId
      )
    }
    return true
  }

  private func recordSyncRunDiagnostics(
    accountId: Int64, statusClass: DiagnosticsStatusClass, durationMilliseconds: Double
  ) async {
    await diagnostics.record(
      DiagnosticsEvent(
        category: .syncRun,
        statusClass: statusClass,
        durationMilliseconds: durationMilliseconds,
        endpointTemplate: EndpointTemplate("/api/libraries/:id/items")
      ),
      accountId: accountId
    )
  }

  private static func errorCategory(for error: Error) -> String {
    guard let apiError = error as? APIError else { return "unknown" }
    switch apiError {
    case .transport: return "transport"
    case .badRequest: return "badRequest"
    case .unauthorized: return "unauthorized"
    case .forbidden: return "forbidden"
    case .notFound: return "notFound"
    case .payloadTooLarge: return "payloadTooLarge"
    case .rateLimited: return "rateLimited"
    case .serverFailure: return "serverFailure"
    case .unexpectedStatus: return "unexpectedStatus"
    case .decoding: return "decoding"
    case .ambiguousLocalSessionResponse: return "ambiguousLocalSessionResponse"
    case .incompatibleServer: return "incompatibleServer"
    case .invalidServerConfiguration: return "invalidServerConfiguration"
    case .cancelled: return "cancelled"
    }
  }
}
