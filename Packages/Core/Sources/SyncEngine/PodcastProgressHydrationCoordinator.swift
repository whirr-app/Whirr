import ABSApi
import Foundation
import Persistence

/// Lands the episode-level progress a library pull structurally cannot.
///
/// `/api/me` keys book progress to the library item, so the pull writes it with the saved page.
/// Podcast progress is keyed to an episode and the minified page carries none, so there is no
/// local row for it and Home's Continue Listening query (an inner join) misses it until the user
/// opens each show.
///
/// This pass issues one expanded request per show that needs it, from the `/api/me` rows its
/// caller holds. It ignores power and radio state: it is bounded by what the account has
/// part-heard, converges (a hydrated show is not selected again), and repairs what the user looks
/// for first after signing in.
public struct PodcastProgressHydrationCoordinator: Sendable {
  private let store: PodcastProgressHydrationStore
  private let backoffStore: PodcastCatalogRefreshStore
  private let showRefresh: PodcastRefreshCoordinator
  private let progressMerge = ProgressMergePolicy()
  private let showBudget: Int
  private let now: @Sendable () -> Date
  private let randomSource: @Sendable () -> Double

  public init(
    database: AppDatabase,
    showRefresh: PodcastRefreshCoordinator,
    showBudget: Int = 20,
    now: @escaping @Sendable () -> Date = Date.init,
    randomSource: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
  ) {
    store = PodcastProgressHydrationStore(database: database)
    backoffStore = PodcastCatalogRefreshStore(database: database)
    self.showRefresh = showRefresh
    self.showBudget = max(0, showBudget)
    self.now = now
    self.randomSource = randomSource
  }

  /// A show-level failure is isolated to that show; transport and server failures stop the pass
  /// because they cannot be attributed to an individual show.
  static func isShowLevelFailure(_ error: any Error) -> Bool {
    if (error as? PodcastRefreshError) == .notPodcast { return true }
    guard let apiError = error as? APIError else { return true }
    switch apiError {
    case .decoding, .ambiguousLocalSessionResponse, .notFound: return true
    case .transport, .badRequest, .unauthorized, .forbidden, .payloadTooLarge, .rateLimited,
      .serverFailure, .unexpectedStatus, .incompatibleServer, .invalidServerConfiguration,
      .cancelled:
      return false
    }
  }

  /// `progressIsComplete` says `progress` is a snapshot fetched in this run with every row decoded;
  /// only then can it evidence another device's reset of an episode.
  public func hydrate(
    accountId: Int64, progress: [MediaProgress], progressIsComplete: Bool = false
  ) async {
    let reconciliation = Self.reconciliationObservations(
      in: progress, snapshotIsComplete: progressIsComplete)
    if reconciliation.observations.isEmpty == false || reconciliation.isComplete {
      try? await store.reconcileKnownProgress(
        accountId: accountId, observations: reconciliation.observations,
        progressSnapshotIsComplete: reconciliation.isComplete
      ) { context in
        guard let current = context.currentProgress else { return .applyServer }
        let decision = progressMerge.resolve(
          current: ProgressMergePolicy.CurrentState(
            currentTime: current.currentTime,
            isFinished: current.isFinished,
            serverUpdatedAt: current.serverUpdatedAt,
            localSequence: current.localSequence,
            originKey: current.originKey,
            hasUnacknowledgedLocalOperation: context.hasUnacknowledgedLocalOperation),
          incoming: ProgressMergePolicy.IncomingObservation(
            currentTime: context.incomingCurrentTime,
            isFinished: context.incomingIsFinished,
            serverUpdatedAt: context.incomingServerUpdatedAt,
            originKey: ProgressMergePolicy.serverOriginKey,
            signalsExplicitResetOrUnfinished: ProgressResetEvidence.isEvidenced(context)),
          duration: context.durationSeconds)
        switch decision {
        case .applyServer:
          return .applyServer
        case .needsResolution:
          return .recordConflict(detectedAt: now())
        case .keepLocal, .rejectStale:
          return .keepLocal
        }
      }
    }

    guard showBudget > 0 else { return }
    let identities = Self.partiallyPlayedIdentities(in: progress)
    guard identities.isEmpty == false else { return }

    let needs: [PodcastProgressHydrationNeed]
    do {
      needs = try await store.showsNeedingHydration(
        accountId: accountId, identities: identities, now: now(), limit: showBudget)
    } catch {
      return
    }

    for need in needs {
      guard Task.isCancelled == false else { return }
      do {
        _ = try await showRefresh.refresh(
          itemID: need.serverItemID, prefetchedDetail: nil, progressSnapshot: progress,
          progressSnapshotIsComplete: progressIsComplete)
      } catch is CancellationError {
        return
      } catch {
        guard Self.isShowLevelFailure(error) else { return }
        try? await backoffStore.recordShowFailure(
          itemID: need.localItemID, at: now(), randomUnit: randomSource())
      }
    }
  }

  /// `isComplete` holds only when every episode row became an observation: a row dropped here
  /// would otherwise read as a deleted one.
  private static func reconciliationObservations(
    in progress: [MediaProgress], snapshotIsComplete: Bool
  ) -> (observations: [PodcastProgressReconciliationObservation], isComplete: Bool) {
    let snapshot = ProgressByIdentity(rows: progress, isComplete: snapshotIsComplete)
    let preferred = snapshot.episodeByShowID
    let isComplete =
      snapshotIsComplete && progress.allSatisfy { $0.episodeID == nil || $0.currentTime != nil }
    let observations = preferred.keys.sorted().flatMap { serverItemID in
      let episodes = preferred[serverItemID] ?? [:]
      return episodes.keys.sorted().compactMap {
        serverEpisodeID -> PodcastProgressReconciliationObservation? in
        guard let row = episodes[serverEpisodeID], let currentTime = row.currentTime else {
          return nil
        }
        return PodcastProgressReconciliationObservation(
          identity: PodcastProgressIdentity(
            serverItemID: serverItemID, serverEpisodeID: serverEpisodeID),
          currentTime: currentTime,
          isFinished: row.isFinished,
          hideFromContinueListening: row.hideFromContinueListening,
          serverUpdatedAt: row.lastUpdate,
          serverRow: ServerRowObservation(
            progressId: row.serverProgressID,
            rowIDs: snapshot.episodeRowIDsByShowID[serverItemID]?[serverEpisodeID] ?? [],
            startedAt: row.startedAt,
            snapshotIsComplete: isComplete))
      }
    }
    return (observations, isComplete)
  }

  /// Most recently listened first, so a budget-truncated pass spends its requests where the user
  /// will look. Rows without a server timestamp sort last but stay in a deterministic order.
  private static func partiallyPlayedIdentities(in progress: [MediaProgress]) -> [PodcastProgressIdentity] {
    progress
      .filter { row in
        guard row.episodeID != nil else { return false }
        guard row.isFinished == false, row.hideFromContinueListening == false else { return false }
        return (row.currentTime ?? 0) > 0
      }
      .sorted { lhs, rhs in
        let lhsUpdate = lhs.lastUpdate ?? .distantPast
        let rhsUpdate = rhs.lastUpdate ?? .distantPast
        if lhsUpdate != rhsUpdate { return lhsUpdate > rhsUpdate }
        if lhs.libraryItemID != rhs.libraryItemID { return lhs.libraryItemID < rhs.libraryItemID }
        return (lhs.episodeID ?? "") < (rhs.episodeID ?? "")
      }
      .compactMap { row in
        row.episodeID.map {
          PodcastProgressIdentity(serverItemID: row.libraryItemID, serverEpisodeID: $0)
        }
      }
  }
}
