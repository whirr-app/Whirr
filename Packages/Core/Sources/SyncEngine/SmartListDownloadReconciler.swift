import Foundation
import Persistence

// MARK: - Boundaries

/// The store calls the smart-list reconciler makes. `SmartListDownloadStore` is the production one.
public protocol SmartListDownloadStoring: Sendable {
  func wantedEpisodes() async throws -> [SmartListWantedEpisode]
  func claims() async throws -> [SmartListDownloadClaimRecord]
  func recordClaim(
    listID: Int64, itemID: String, episodeID: String, accountID: Int64?, at date: Date
  ) async throws
  func dropClaim(listID: Int64, itemID: String, episodeID: String) async throws
  func hasClaim(itemID: String, episodeID: String, excluding listID: Int64?) async throws -> Bool
  func requestState(itemID: String, episodeID: String, accountID: Int64?) async throws
    -> SmartListRequestState
  func isKeptBesidesClaims(itemID: String, episodeID: String, accountID: Int64?) async throws -> Bool
  func deleteList(id: Int64) async throws
  @discardableResult func pruneHiddenEpisodes() async throws -> Int
  @discardableResult func pruneDeclines() async throws -> Int
}

extension SmartListDownloadStore: SmartListDownloadStoring {}

/// The download intents a smart list needs: an episode request, an episode release, and the
/// low-disk pause. `DownloadCoordinator` dispatches native and Audiobookshelf episodes itself.
public protocol SmartListDownloadRequesting: Sendable {
  func requestEpisodeDownload(itemID: String, episodeID: String) async throws
  func purgeEpisodeDownload(itemID: String, episodeID: String, source: DownloadPurgeSource) async throws
  func isQueuePausedForLowDisk() async -> Bool
}

extension DownloadCoordinator: SmartListDownloadRequesting {}

// MARK: - Reconciler

/// Keeps the top episodes of every auto-downloading smart list downloaded, whether or
/// not a list is playing. Each pass releases claims whose episode left its list's wanted set, then
/// requests up to `maxRequestsPerPass` wanted episodes that have no download row of any origin.
/// Concurrent callers share one in-flight pass.
///
/// An episode the listener removed by hand is declined (`SmartListDecliningDownloadIntents`) and
/// is neither requested nor claimed again until it is finished, gone or downloaded by hand; it
/// keeps its place in the limit.
///
/// Only an episode with no row is requested and claimed: requesting one that already has an
/// `.automatic` row would promote it to `.manual`, out of the reaper's reach, and claim a download
/// the list did not start. An episode downloaded by something else is satisfied, not claimed,
/// unless another list already claims it, so two lists sharing an episode keep it while either
/// wants it. A request returns nothing, so creation is inferred: no row beforehand, no throw.
///
/// It runs with no account: native episodes only, and a server episode's request, claim and
/// release wait until an account exists.
public actor SmartListDownloadReconciler: CoalescedPassHost {
  /// Matches `PinnedListDownloadReconciler.maxRequestsPerPass`.
  static let maxRequestsPerPass = 20

  private let accountID: Int64?
  private let store: any SmartListDownloadStoring
  private let requesting: any SmartListDownloadRequesting
  private let networkConditions: any NetworkConditions
  private let nativeSettings: any PodcastSettingsReading
  private let serverSettings: any PodcastSettingsReading
  private let diagnostics: any DiagnosticsRecording
  private let now: @Sendable () -> Date

  private struct EpisodeKey: Hashable {
    let itemID: String
    let episodeID: String
  }

  /// Episodes whose request failed for a reason another try cannot fix. Process-lifetime only,
  /// so a relaunch tries them once more.
  private var refused: Set<EpisodeKey> = []

  var passSlot = CoalescedPassSlot<Void>()
  var joinedFlightCount: Int { passSlot.joinedCount }
  public init(
    accountID: Int64?,
    store: any SmartListDownloadStoring,
    requesting: any SmartListDownloadRequesting,
    networkConditions: any NetworkConditions,
    nativeSettings: any PodcastSettingsReading,
    serverSettings: any PodcastSettingsReading,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.accountID = accountID
    self.store = store
    self.requesting = requesting
    self.networkConditions = networkConditions
    self.nativeSettings = nativeSettings
    self.serverSettings = serverSettings
    self.diagnostics = diagnostics
    self.now = now
  }

  /// Runs one pass. Concurrent callers coalesce onto the same in-flight pass.
  public func run() async {
    await runCoalescedPass(policy: .shareInFlight) { await self.perform() }
  }

  /// Runs a pass a moment after the wanted set last changed. The stream is
  /// `SmartListDownloadStore.observeWantedEpisodes()`; it ends with the calling task.
  public func runOnChanges(
    _ changes: AsyncStream<[SmartListWantedEpisode.Key]>, debounce: Duration = .seconds(2)
  ) async {
    var pending: Task<Void, Never>?
    for await _ in changes {
      pending?.cancel()
      pending = Task { [weak self] in
        try? await Task.sleep(for: debounce)
        guard Task.isCancelled == false else { return }
        await self?.run()
      }
    }
    pending?.cancel()
  }

  /// Deletes the list, then releases the downloads it alone claimed. The claim rows cascade with
  /// the list, so they are read first. The delete never waits on a release: a release that fails
  /// leaves a file the user can remove, where a list that will not delete strands the user. It
  /// does not wait for a pass in flight either; a pass that claims for the list after it is gone
  /// fails the claim's foreign key.
  public func deleteList(_ listID: Int64) async throws {
    let claims = try await store.claims().filter { $0.listId == listID }
    try await store.deleteList(id: listID)
    for claim in claims where canReach(claim) {
      try? await releaseFile(claim)
    }
  }

  // MARK: Pass

  private func perform() async {
    let startedAt = now()
    // A failed read must not look like an empty wanted set: that would release everything.
    guard let wanted = try? await store.wantedEpisodes(), var claims = try? await store.claims()
    else {
      await recordDiagnostic(failed: true, startedAt: startedAt)
      return
    }
    guard wanted.isEmpty == false || claims.isEmpty == false else { return }

    var failureCount = 0
    if (try? await store.pruneHiddenEpisodes()) == nil { failureCount += 1 }
    if (try? await store.pruneDeclines()) == nil { failureCount += 1 }

    let reachable = wanted.filter { $0.source == .native || accountID != nil }
    let wantedKeys = Set(reachable.map(\.key))
    for claim in claims where canReach(claim) {
      guard Task.isCancelled == false else { break }
      let key = SmartListWantedEpisode.Key(
        listID: claim.listId, itemID: claim.itemID, episodeID: claim.episodeID)
      guard wantedKeys.contains(key) == false else { continue }
      do {
        try await release(claim)
      } catch {
        failureCount += 1
      }
    }

    // Releasing frees space, so only requests wait out a gate.
    if let claimsAfterRelease = try? await store.claims() { claims = claimsAfterRelease }
    failureCount += await requestEpisodes(reachable, claims: claims)
    await recordDiagnostic(failed: failureCount > 0, startedAt: startedAt)
  }

  /// A server claim is released only while its account is signed in; signed out, the purge could
  /// not find the row, and dropping the claim would strand the file.
  private func canReach(_ claim: SmartListDownloadClaimRecord) -> Bool {
    if PodcastSourceIdentity(itemId: claim.itemID)?.rssFeedId != nil { return true }
    return accountID != nil && claim.accountId == accountID
  }

  /// Drops a claim whose episode left its list's wanted set, and purges the download when no
  /// claim remains and nothing else keeps it. A purge that throws keeps the claim for the next
  /// pass; a row already gone (Delete After Playing) purges as a no-op.
  private func release(_ claim: SmartListDownloadClaimRecord) async throws {
    try await releaseFile(claim)
    try await store.dropClaim(
      listID: claim.listId, itemID: claim.itemID, episodeID: claim.episodeID)
  }

  /// Purges the claimed episode's file unless another list claims it or something else keeps it.
  private func releaseFile(_ claim: SmartListDownloadClaimRecord) async throws {
    let stillClaimed = try await store.hasClaim(
      itemID: claim.itemID, episodeID: claim.episodeID, excluding: claim.listId)
    if stillClaimed == false,
      try await store.isKeptBesidesClaims(
        itemID: claim.itemID, episodeID: claim.episodeID, accountID: accountID) == false
    {
      try await requesting.purgeEpisodeDownload(
        itemID: claim.itemID, episodeID: claim.episodeID, source: .smartListRelease)
    }
  }

  // MARK: Requests

  private func requestEpisodes(
    _ wanted: [SmartListWantedEpisode], claims: [SmartListDownloadClaimRecord]
  ) async -> Int {
    guard wanted.isEmpty == false, let admission = await admission(),
      await requesting.isQueuePausedForLowDisk() == false
    else { return 0 }

    var listsByEpisode: [EpisodeKey: [SmartListWantedEpisode]] = [:]
    var order: [EpisodeKey] = []
    for episode in wanted {
      let key = EpisodeKey(itemID: episode.itemID, episodeID: episode.episodeID)
      if listsByEpisode[key] == nil { order.append(key) }
      listsByEpisode[key, default: []].append(episode)
    }
    var claimed = Set(
      claims.map {
        SmartListWantedEpisode.Key(listID: $0.listId, itemID: $0.itemID, episodeID: $0.episodeID)
      })

    var failureCount = 0
    var requested = 0
    for key in order where refused.contains(key) == false {
      guard Task.isCancelled == false, requested < Self.maxRequestsPerPass else { break }
      guard let wanting = listsByEpisode[key], let source = wanting.first?.source,
        admission.allows(source)
      else { continue }
      do {
        // Read at request time, so a decline or a download made since the wanted set was read
        // still counts.
        switch try await store.requestState(
          itemID: key.itemID, episodeID: key.episodeID, accountID: accountID)
        {
        case .declined:
          continue
        case .hasDownloadRow:
          // Satisfied by something else, or by another list's claim, which this one then shares.
          guard wanting.contains(where: { claimed.contains($0.key) }) else { continue }
        case .requestable:
          try await requesting.requestEpisodeDownload(itemID: key.itemID, episodeID: key.episodeID)
          requested += 1
        }
        for episode in wanting where claimed.contains(episode.key) == false {
          try await store.recordClaim(
            listID: episode.listID, itemID: key.itemID, episodeID: key.episodeID,
            accountID: source == .native ? nil : accountID, at: now())
          claimed.insert(episode.key)
        }
      } catch {
        failureCount += 1
        if Self.isPermanent(error) { refused.insert(key) }
      }
    }
    return failureCount
  }

  /// What request-time admission lets through. A refused pass requests nothing and retries on
  /// the next trigger (the Wi-Fi transition among them).
  private struct Admission {
    let native: Bool
    let server: Bool

    func allows(_ source: SmartListShowSource) -> Bool {
      source == .native ? native : server
    }
  }

  /// Copies the per-show auto-download gate: refuse in Low Power Mode, and on a constrained or
  /// cellular link admit each half only under its own `allowCellularAutoDownload`. The transfer
  /// gate does not apply that setting to a `.manual` row, so it is checked here.
  private func admission() async -> Admission? {
    guard networkConditions.isLowPowerMode == false else { return nil }
    guard networkConditions.isConstrainedOrCellular else { return Admission(native: true, server: true) }
    let native = await allowsCellular(nativeSettings)
    let server = accountID != nil ? await allowsCellular(serverSettings) : false
    guard native || server else { return nil }
    return Admission(native: native, server: server)
  }

  /// One-shot read: the observation yields its current value on subscription.
  private func allowsCellular(_ reading: any PodcastSettingsReading) async -> Bool {
    for await settings in reading.observeGlobalSettings() {
      return settings.allowCellularAutoDownload
    }
    return false
  }

  /// Failures that say the episode itself cannot be downloaded, an Audiobookshelf episode missing
  /// its stored ino, size, MIME type or duration among them. Network, sign-in and account removal
  /// failures are not about the episode.
  private static func isPermanent(_ error: any Error) -> Bool {
    switch error as? DownloadPlanningError {
    case .unknownItem, .unknownPodcastEpisode, .episodeUnavailable, .podcastEpisodesUnsupported,
      .metadataValidationFailed:
      true
    case .notAuthenticated, .accountRemovalInProgress, nil:
      false
    }
  }

  private func recordDiagnostic(failed: Bool, startedAt: Date) async {
    guard let accountID else { return }
    await diagnostics.record(
      DiagnosticsEvent(
        category: .download, statusClass: failed ? .clientError : .success,
        durationMilliseconds: SyncEngine.durationMilliseconds(startedAt: startedAt, endedAt: now())),
      accountId: accountID)
  }
}
