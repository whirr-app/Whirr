import Foundation
import Persistence

// MARK: - Reap store boundary

/// What `PodcastAutoDownloadReaper` needs from `PodcastAutoDownloadReapStore` (Persistence).
/// Narrowed to a protocol so tests drive the pass against a plain fake instead of a real database.
public protocol PodcastAutoDownloadReapCandidateProviding: Sendable {
  func reapCandidates() async throws -> [EpisodeDownloadKey]
  /// Supplies a live deletion-time playback check. Non-RSS providers have no device-owned RSS
  /// playback tracker, so the default is an always-false predicate.
  func activePlaybackExclusion() -> @Sendable (Int64) -> Bool
}

extension PodcastAutoDownloadReapCandidateProviding {
  public func activePlaybackExclusion() -> @Sendable (Int64) -> Bool { { _ in false } }
}

/// Both persistence stores implement `reapCandidates`; the RSS store additionally overrides the
/// live playback predicate while the ABS store uses the always-false default. These structural
/// conformances are the whole of the wiring.
extension PodcastAutoDownloadReapStore: PodcastAutoDownloadReapCandidateProviding {}
extension RSSPodcastAutoDownloadReapStore: PodcastAutoDownloadReapCandidateProviding {}

// MARK: - Purge boundary

/// The episode purge methods the reap pass needs from
/// `DownloadIntents.purgeEpisodeDownload(itemID:episodeID:source:)`. Narrowed to this single method
/// because the pass never requests, pauses, or resumes anything.
/// `DownloadCoordinator` implements both methods; the extension below wires the real seam.
public protocol PodcastAutoDownloadPurging: Sendable {
  func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws
  /// Reaper-only overload. The predicate is evaluated by the concrete purge boundary inside its
  /// deletion transaction; the default preserves existing lightweight fakes and ABS behavior.
  func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource,
    activePlaybackExclusion: @escaping @Sendable (Int64) -> Bool
  ) async throws
}

extension PodcastAutoDownloadPurging {
  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource,
    activePlaybackExclusion: @escaping @Sendable (Int64) -> Bool
  ) async throws {
    _ = activePlaybackExclusion
    try await purgeEpisodeDownload(itemID: itemID, episodeID: episodeID, source: source)
  }
}

extension DownloadCoordinator: PodcastAutoDownloadPurging {}

/// Default conformance: every purge is a silent no-op, so a composition that has not wired the
/// real seam keeps existing fake-composed tests compiling unchanged.
public struct NoOpPodcastAutoDownloadPurging: PodcastAutoDownloadPurging, Sendable {
  public init() {}
  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {}
}

// MARK: - Reaper

/// The reap pass: queries the store and forwards each identity to the purge boundary, sequentially
/// in the store's deterministic order. One purge failure does not stop the rest; the failing row
/// survives, so the store's idempotent query offers it on a later pass (triggered elsewhere).
/// Nothing retries within one call; no timer or detached task.
///
/// Concurrent callers coalesce onto the in-flight pass with the same `Flight` pattern as
/// `PodcastAutoDownloadCoordinator.run`, except a caller joining mid-pass also requests one
/// trailing pass, since the in-flight pass may have read its candidates before the change that
/// prompted the request.
public actor PodcastAutoDownloadReaper: CoalescedPassHost {
  private let reapCandidateProvider: any PodcastAutoDownloadReapCandidateProviding
  private let purging: any PodcastAutoDownloadPurging
  private let diagnostics: any DiagnosticsRecording
  /// `nil` means "no account resolved yet". `DiagnosticsEvent.accountId` is a not-null foreign key,
  /// so a stand-in id would fail that constraint and be silently swallowed by `DiagnosticsStore`'s
  /// best-effort write.
  private let accountId: Int64?
  private let now: @Sendable () -> Date

  var passSlot = CoalescedPassSlot<Void>()

  /// How many callers have joined an already-in-flight pass instead of starting their own. The
  /// only observable that says a second trigger has reached `reap`.
  var joinedFlightCount: Int { passSlot.joinedCount }

  public init(
    reapCandidateProvider: any PodcastAutoDownloadReapCandidateProviding,
    purging: any PodcastAutoDownloadPurging = NoOpPodcastAutoDownloadPurging(),
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    accountId: Int64? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.reapCandidateProvider = reapCandidateProvider
    self.purging = purging
    self.diagnostics = diagnostics
    self.accountId = accountId
    self.now = now
  }

  /// Runs one reap pass. A caller that arrives while a pass is in flight returns only after a pass
  /// that started after its request; any number of such callers share one trailing pass.
  public func reap() async {
    await runCoalescedPass(policy: .trailingPass) { await self.perform() }
  }

  /// Cancels the in-flight pass and any trailing pass it owes. The next cancellation check stops
  /// before another purge.
  public func cancel() {
    passSlot.flight?.task.cancel()
  }

  private func perform() async {
    let startedAt = now()
    guard let candidates = try? await reapCandidateProvider.reapCandidates() else {
      await recordDiagnostic(statusClass: .clientError, startedAt: startedAt)
      return
    }
    let activePlaybackExclusion = reapCandidateProvider.activePlaybackExclusion()

    var failureCount = 0
    for candidate in candidates {
      guard Task.isCancelled == false else { return }
      do {
        try await purging.purgeEpisodeDownload(
          itemID: candidate.itemID, episodeID: candidate.episodeID, source: .autoDownloadReaper,
          activePlaybackExclusion: activePlaybackExclusion)
      } catch {
        // Isolated: the rest of the pass still runs. The failed identity's row survives, so it
        // stays a candidate and the store's idempotent query offers it again on a later pass.
        failureCount += 1
      }
    }

    await recordDiagnostic(
      statusClass: failureCount > 0 ? .clientError : .success, startedAt: startedAt)
  }

  /// Aggregate and privacy-safe: category, timing and outcome only, never a show/episode id, title,
  /// URL, or credential. `DiagnosticsEvent`'s closed shape has no field for a reaped/failed-count
  /// breakdown, so those counts are not encoded here.
  private func recordDiagnostic(statusClass: DiagnosticsStatusClass, startedAt: Date) async {
    guard let accountId else { return }
    let durationMilliseconds = SyncEngine.durationMilliseconds(
      startedAt: startedAt, endedAt: now())
    await diagnostics.record(
      DiagnosticsEvent(
        category: .download, statusClass: statusClass, durationMilliseconds: durationMilliseconds),
      accountId: accountId)
  }
}
