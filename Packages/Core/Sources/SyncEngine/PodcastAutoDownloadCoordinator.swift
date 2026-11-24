import Foundation
import Persistence

// MARK: - Selection store boundary

/// What `PodcastAutoDownloadCoordinator` needs from `PodcastAutoDownloadSelectionStore`
/// (Persistence), narrowed to a protocol so tests drive the pass against a plain fake instead of
/// a real database.
public protocol PodcastAutoDownloadSelecting: Sendable {
  func fetchCandidates(maxPerShow: Int, maxPerPass: Int) async throws
    -> [PodcastAutoDownloadCandidate]
  func markDecided(itemID: String, episodeID: String) async throws
  @discardableResult
  func repairDecidedStamps() async throws -> Int
}

/// `PodcastAutoDownloadSelectionStore` already implements every method above with matching
/// signatures, so this empty conformance is the whole of the wiring.
extension PodcastAutoDownloadSelectionStore: PodcastAutoDownloadSelecting {}
extension RSSPodcastAutoDownloadSelectionStore: PodcastAutoDownloadSelecting {}

// MARK: - Low-disk gate boundary

/// The one signal the automatic pass needs from the download queue's low-disk pause
/// (`DownloadIntents.isQueuePausedForLowDisk`), narrowed to a single method so the pass does not
/// depend on the full `DownloadIntents` surface. `DownloadCoordinator` already implements a method
/// with this signature, so an empty `extension DownloadCoordinator:
/// PodcastAutoDownloadLowDiskGating {}` wires the real seam.
public protocol PodcastAutoDownloadLowDiskGating: Sendable {
  func isQueuePausedForLowDisk() async -> Bool
}

/// Default conformance: never paused, for compositions that have not wired the real seam.
public struct NoOpPodcastAutoDownloadLowDiskGating: PodcastAutoDownloadLowDiskGating, Sendable {
  public init() {}
  public func isQueuePausedForLowDisk() async -> Bool { false }
}

/// The pass: gates, candidates, plan, decide. Selection is a deterministic database query, not an
/// event hook, so every trigger reconciles the whole account, not the one show that changed.
///
/// No timer, retry loop or detached task: `run()` does one bounded pass per call, coalescing
/// concurrent callers onto one in-flight pass.
public actor PodcastAutoDownloadCoordinator: CoalescedPassHost {
  private let selecting: any PodcastAutoDownloadSelecting
  private let planner: any AutomaticEpisodeDownloadPlanning
  private let accountLifecycle: any AccountLifecycle
  private let networkConditions: any NetworkConditions
  private let podcastSettingsReading: any PodcastSettingsReading
  private let lowDiskGating: any PodcastAutoDownloadLowDiskGating
  private let diagnostics: any DiagnosticsRecording
  /// `nil` means "no account resolved yet": `DiagnosticsEvent.accountId` is a not-null foreign
  /// key, so a stand-in id would fail that constraint and be silently swallowed by
  /// `DiagnosticsStore`'s best-effort write.
  private let accountId: Int64?
  private let policy: PodcastAutoDownloadPolicy
  private let now: @Sendable () -> Date

  var passSlot = CoalescedPassSlot<Void>()

  /// How many callers joined an in-flight pass instead of starting their own. The only observable
  /// that a second trigger reached `run`: every other signal a coalescing test could wait on
  /// (HTTP traffic, a submission recorder) fires before the commit preceding the call, leaving the
  /// join a race.
  var joinedFlightCount: Int { passSlot.joinedCount }

  public init(
    selecting: any PodcastAutoDownloadSelecting,
    planner: any AutomaticEpisodeDownloadPlanning,
    accountLifecycle: any AccountLifecycle,
    networkConditions: any NetworkConditions,
    podcastSettingsReading: any PodcastSettingsReading,
    lowDiskGating: any PodcastAutoDownloadLowDiskGating = NoOpPodcastAutoDownloadLowDiskGating(),
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    accountId: Int64? = nil,
    policy: PodcastAutoDownloadPolicy = PodcastAutoDownloadPolicy(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.selecting = selecting
    self.planner = planner
    self.accountLifecycle = accountLifecycle
    self.networkConditions = networkConditions
    self.podcastSettingsReading = podcastSettingsReading
    self.lowDiskGating = lowDiskGating
    self.diagnostics = diagnostics
    self.accountId = accountId
    self.policy = policy
    self.now = now
  }

  /// Runs one pass. Concurrent callers coalesce onto the same in-flight pass rather than each
  /// starting their own.
  public func run() async {
    await runCoalescedPass(policy: .shareInFlight) { await self.perform() }
  }

  /// Cancels the in-flight pass, if any. A cancelled pass stops starting new plans but leaves
  /// every already-committed decision (a planned download whose `markDecided` already landed)
  /// intact.
  public func cancel() {
    passSlot.flight?.task.cancel()
  }

  private func perform() async {
    let startedAt = now()
    guard await gatesAllow() else {
      await recordDiagnostic(statusClass: .clientError, startedAt: startedAt)
      return
    }

    // Crash heal: a process that died between `DownloadCoordinator` creating a row and
    // `markDecided` landing leaves a row with no stamp. Repairing first keeps the candidate query
    // below from re-offering it.
    _ = try? await selecting.repairDecidedStamps()

    let candidates: [PodcastAutoDownloadCandidate]
    do {
      candidates = try await selecting.fetchCandidates(
        maxPerShow: policy.maxEpisodesPerShow, maxPerPass: policy.maxEpisodesPerPass)
    } catch {
      await recordDiagnostic(statusClass: .clientError, startedAt: startedAt)
      return
    }

    for candidate in candidates {
      guard Task.isCancelled == false else { break }
      do {
        try await planner.requestAutomaticEpisodeDownload(
          itemID: candidate.itemID, episodeID: candidate.episodeID)
      } catch {
        // A planning failure (transient or an `episodeUnavailable`-style rejection) leaves this
        // candidate undecided, so it stays eligible for a later pass, and does not stop the
        // remaining candidates.
        continue
      }
      // Stamped only once a download row exists. A failure between the planner returning and this
      // landing is what `repairDecidedStamps()` heals on the next pass.
      try? await selecting.markDecided(itemID: candidate.itemID, episodeID: candidate.episodeID)
    }

    await recordDiagnostic(
      statusClass: Task.isCancelled ? .cancelled : .success, startedAt: startedAt)
  }

  /// Every gate, checked before any candidate query. A blocked pass decides nothing and enqueues
  /// nothing.
  private func gatesAllow() async -> Bool {
    guard accountLifecycle.isAuthenticated else { return false }
    if (try? await accountLifecycle.isRemovalPending()) == true { return false }
    guard networkConditions.isLowPowerMode == false else { return false }
    if networkConditions.isConstrainedOrCellular {
      guard await allowCellularAutoDownload() else { return false }
    }
    if await lowDiskGating.isQueuePausedForLowDisk() { return false }
    return true
  }

  /// One-shot read of the global `allowCellularAutoDownload` setting. `observeGlobalSettings()`
  /// is a `ValueObservation`-backed stream that yields its current value on subscription
  /// (`PodcastSettingsStore.stream`'s contract), so taking the first element and returning is a
  /// one-shot read. A pass only needs the setting as it stood at gate-check time.
  private func allowCellularAutoDownload() async -> Bool {
    for await settings in podcastSettingsReading.observeGlobalSettings() {
      return settings.allowCellularAutoDownload
    }
    return false
  }

  /// Aggregate and privacy-safe: category/timing/outcome only, like every other `.download` event
  /// `DownloadCoordinator` records. Never a show/episode id, title, URL or credential.
  /// `DiagnosticsEvent`'s closed shape has no field for a considered/enqueued/skipped breakdown or
  /// a labelled gate-block reason, so those counts are not recorded.
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
