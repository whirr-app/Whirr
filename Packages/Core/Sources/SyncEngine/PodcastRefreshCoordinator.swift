import ABSApi
import Foundation
import Persistence

public actor PodcastRefreshCoordinator: PodcastRefreshing {
  public typealias ContextResolver =
    @Sendable (_ serverItemID: String) async throws -> PodcastRefreshContext

  private struct RequestKey: Hashable {
    let accountID: Int64
    let itemID: String
  }

  private let client: ABSClient
  private let persistence: any PodcastRefreshApplying
  private let diagnostics: any DiagnosticsRecording
  private let resolveContext: ContextResolver
  private let progressMerge = ProgressMergePolicy()
  private let now: @Sendable () -> Date
  /// Run after a committed show refresh, then the reaper. The same trigger serves foreground and
  /// background, since the show screen's explicit refresh and the progress-hydration pass both
  /// funnel through this one `refresh` implementation. `nil` is a no-op, as for `SyncEngine`'s
  /// recent-episodes trigger.
  private let podcastAutoDownload: PodcastAutoDownloadCoordinator?
  private let podcastAutoDownloadReaper: PodcastAutoDownloadReaper?
  private struct Flight {
    let id: UUID
    let task: Task<PodcastRefreshOutcome, Error>
    var waiters: Set<UUID>
  }

  private var inFlight: [RequestKey: Flight] = [:]

  /// Test/composition initializer. The resolver remains behind SyncEngine's public refresh
  /// boundary; callers of `refresh` never supply account identity.
  public init(
    client: ABSClient,
    persistence: any PodcastRefreshApplying,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    resolveContext: @escaping ContextResolver,
    podcastAutoDownload: PodcastAutoDownloadCoordinator? = nil,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.client = client
    self.persistence = persistence
    self.diagnostics = diagnostics
    self.resolveContext = resolveContext
    self.podcastAutoDownload = podcastAutoDownload
    self.podcastAutoDownloadReaper = podcastAutoDownloadReaper
    self.now = now
  }

  /// Production resolver for the single persisted account and the selected local item.
  public init(
    database: AppDatabase,
    client: ABSClient,
    persistence: any PodcastRefreshApplying,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    podcastAutoDownload: PodcastAutoDownloadCoordinator? = nil,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper? = nil
  ) {
    let accountDAO = AccountDAO(database: database)
    let itemDAO = ItemDAO(database: database)
    self.init(
      client: client, persistence: persistence, diagnostics: diagnostics,
      resolveContext: { serverItemID in
        guard let accountRecord = try await accountDAO.fetchAsync(), let accountID = accountRecord.id
        else { throw PodcastRefreshError.accountUnavailable }
        guard
          let item = try itemDAO.fetchOne(accountId: accountID, serverItemId: serverItemID),
          let localItemID = item.id
        else { throw PodcastRefreshError.itemUnavailable }
        let tokenAccount = try accountRecord.credentialTokenAccount
        return PodcastRefreshContext(
          accountID: accountID,
          localItemID: localItemID,
          tokenAccount: tokenAccount)
      },
      podcastAutoDownload: podcastAutoDownload,
      podcastAutoDownloadReaper: podcastAutoDownloadReaper)
  }

  public func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    try await refresh(
      itemID: itemID,
      prefetchedDetail: nil,
      progressSnapshot: nil,
      forceIncompleteEpisodeList: false)
  }

  /// Batch/hydration entry point. A supplied progress array (including an empty one) prevents
  /// another account-wide `/api/me` request. Prefetched batch details are never complete for
  /// deletion inference because batch diagnostics cannot be attributed to a single show.
  /// `progressSnapshotIsComplete` says the supplied snapshot decoded whole in a successful fetch;
  /// only then can it evidence another device's reset.
  public func refresh(
    itemID: String,
    prefetchedDetail: ItemDetail?,
    progressSnapshot: [MediaProgress]?,
    progressSnapshotIsComplete: Bool = false
  ) async throws -> PodcastRefreshOutcome {
    try await refresh(
      itemID: itemID,
      prefetchedDetail: prefetchedDetail,
      progressSnapshot: progressSnapshot.map {
        UserProgressSnapshot(
          progress: $0, hiddenSeriesIDs: [], isComplete: progressSnapshotIsComplete)
      },
      forceIncompleteEpisodeList: prefetchedDetail != nil)
  }

  private func refresh(
    itemID: String,
    prefetchedDetail: ItemDetail?,
    progressSnapshot: UserProgressSnapshot?,
    forceIncompleteEpisodeList: Bool
  ) async throws -> PodcastRefreshOutcome {
    let context: PodcastRefreshContext
    do {
      context = try await resolveContext(itemID)
    } catch {
      // Resolution failures never reach the flight task's own `catch` below, and no diagnostics
      // UI exists to surface either, so without this `accountUnavailable`/`itemUnavailable` reach
      // the user only as the generic "Couldn't load episodes."
      Self.logFailure(itemID: itemID, stage: "resolve", error: error)
      throw error
    }
    let key = RequestKey(accountID: context.accountID, itemID: itemID)
    let waiterID = UUID()
    let flight: Flight
    if var existing = inFlight[key] {
      existing.waiters.insert(waiterID)
      inFlight[key] = existing
      flight = existing
    } else {
      let task = Task<PodcastRefreshOutcome, Error> {
        [
          client, persistence, diagnostics, progressMerge, now, podcastAutoDownload,
          podcastAutoDownloadReaper
        ] in
        let startedAt = now()
        do {
          try Task.checkCancellation()
          let detailDiagnostics = DecodeDiagnostics()
          let detail = try await Self.fetchDetail(
            client: client,
            account: context.tokenAccount,
            itemID: itemID,
            prefetchedDetail: prefetchedDetail,
            diagnostics: detailDiagnostics)
          try Task.checkCancellation()
          guard case .podcast(let podcast)? = detail.media else {
            throw PodcastRefreshError.notPodcast
          }
          let progressDiagnostics = DecodeDiagnostics()
          let progress = try await Self.resolveProgress(
            client: client,
            account: context.tokenAccount,
            progressSnapshot: progressSnapshot,
            progressDiagnostics: progressDiagnostics,
            diagnostics: diagnostics,
            accountID: context.accountID,
            startedAt: startedAt,
            now: now)
          try Task.checkCancellation()
          let refresh = Self.mapRefresh(
            context: context,
            itemID: itemID,
            podcast: podcast,
            progress: progress,
            progressMerge: progressMerge,
            detailDiagnostics: detailDiagnostics,
            forceIncompleteEpisodeList: forceIncompleteEpisodeList,
            now: now,
            requestStartedAt: startedAt)
          try await Self.commitRefresh(
            persistence: persistence,
            refresh: refresh,
            progressMerge: progressMerge,
            now: now)
          await Self.postCommit(
            podcastAutoDownload: podcastAutoDownload,
            podcastAutoDownloadReaper: podcastAutoDownloadReaper,
            diagnostics: diagnostics,
            refresh: refresh,
            progressDiagnostics: progressDiagnostics,
            startedAt: startedAt,
            now: now)
          return refresh.isComplete ? .complete : .partial
        } catch {
          // The error type is the stage: `PodcastRefreshError.notPodcast` is the media guard, an
          // `APIError` is the expanded item request (progress is best-effort above and never
          // arrives here), anything else is the persistence application.
          Self.logFailure(itemID: itemID, stage: "refresh", error: error)
          await Self.recordDiagnostic(
            diagnostics, accountID: context.accountID, category: .syncRun,
            statusClass: Self.statusClass(for: error), startedAt: startedAt, now: now)
          throw error
        }
      }
      flight = Flight(id: UUID(), task: task, waiters: [waiterID])
      inFlight[key] = flight
    }

    do {
      let outcome = try await withTaskCancellationHandler {
        let value = try await flight.task.value
        try Task.checkCancellation()
        return value
      } onCancel: {
        Task { await self.cancelWaiter(waiterID, flightID: flight.id, key: key) }
      }
      finishWaiter(waiterID, flightID: flight.id, key: key)
      return outcome
    } catch {
      finishWaiter(waiterID, flightID: flight.id, key: key)
      throw error
    }
  }

  private func cancelWaiter(_ waiterID: UUID, flightID: UUID, key: RequestKey) {
    guard var flight = inFlight[key], flight.id == flightID else { return }
    flight.waiters.remove(waiterID)
    if flight.waiters.isEmpty {
      inFlight[key] = nil
      flight.task.cancel()
    } else {
      inFlight[key] = flight
    }
  }

  private func finishWaiter(_ waiterID: UUID, flightID: UUID, key: RequestKey) {
    guard var flight = inFlight[key], flight.id == flightID else { return }
    flight.waiters.remove(waiterID)
    inFlight[key] = flight.waiters.isEmpty ? nil : flight
  }
}
