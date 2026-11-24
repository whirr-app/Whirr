import ABSApi
import Foundation
import Persistence

extension PodcastRefreshCoordinator {
  static func fetchDetail(
    client: ABSClient,
    account: TokenAccount,
    itemID: String,
    prefetchedDetail: ItemDetail?,
    diagnostics: DecodeDiagnostics
  ) async throws -> ItemDetail {
    if let prefetchedDetail {
      return prefetchedDetail
    }
    return try await client.fetchItemDetail(
      account: account,
      itemID: itemID,
      diagnostics: diagnostics)
  }

  static func resolveProgress(
    client: ABSClient,
    account: TokenAccount,
    progressSnapshot: UserProgressSnapshot?,
    progressDiagnostics: DecodeDiagnostics,
    diagnostics: any DiagnosticsRecording,
    accountID: Int64,
    startedAt: Date,
    now: @Sendable () -> Date
  ) async throws -> UserProgressSnapshot {
    if let progressSnapshot {
      return progressSnapshot
    }

    // Best-effort, like every other `/api/me` caller in this module (`SyncEngine.
    // fetchProgressByIdentity`, `ResolutionCenter.takeServerSkew`): a server that cannot answer
    // must not discard an episode list that decoded perfectly. Cancellation is this refresh being
    // torn down, not a server failure, and still propagates.
    do {
      return try await client.fetchUserProgressSnapshot(
        account: account,
        diagnostics: progressDiagnostics)
    } catch {
      if error is CancellationError || (error as? APIError) == .cancelled { throw error }
      await Self.recordDiagnostic(
        diagnostics, accountID: accountID, category: .syncRun,
        statusClass: Self.statusClass(for: error), startedAt: startedAt, now: now,
        endpointTemplate: Self.progressEndpointTemplate)
      return UserProgressSnapshot(progress: [], hiddenSeriesIDs: [], isComplete: false)
    }
  }

  static func commitRefresh(
    persistence: any PodcastRefreshApplying,
    refresh: PodcastRefresh,
    progressMerge: ProgressMergePolicy,
    now: @escaping @Sendable () -> Date
  ) async throws {
    try await persistence.applyPodcastRefresh(refresh) { context in
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

  static func postCommit(
    podcastAutoDownload: PodcastAutoDownloadCoordinator?,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper?,
    diagnostics: any DiagnosticsRecording,
    refresh: PodcastRefresh,
    progressDiagnostics: DecodeDiagnostics,
    startedAt: Date,
    now: @Sendable () -> Date
  ) async {
    // After a committed refresh: one auto-download coordinator pass, then reap.
    // `applyPodcastRefresh` throws to the `catch` below on any failed or rolled-back write, so
    // reaching here means the commit landed.
    await podcastAutoDownload?.run()
    await podcastAutoDownloadReaper?.reap()
    if !refresh.isComplete {
      await Self.recordDiagnostic(
        diagnostics, accountID: refresh.accountID, category: .decodeDiagnostic,
        statusClass: .success, startedAt: startedAt, now: now)
    }
    // Worth surfacing, but against the endpoint the problem is in, and never as a statement
    // about this show's episode list or its user-facing outcome.
    if !progressDiagnostics.entries.isEmpty {
      await Self.recordDiagnostic(
        diagnostics, accountID: refresh.accountID, category: .decodeDiagnostic,
        statusClass: .success, startedAt: startedAt, now: now,
        endpointTemplate: Self.progressEndpointTemplate)
    }
    await Self.recordDiagnostic(
      diagnostics, accountID: refresh.accountID, category: .syncRun,
      statusClass: .success, startedAt: startedAt, now: now)
  }
}
