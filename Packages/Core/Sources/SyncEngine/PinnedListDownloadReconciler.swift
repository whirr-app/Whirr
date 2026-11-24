import Foundation
import Persistence

// MARK: - Boundaries

/// The store calls the pinned-list reconciler makes. `PinnedListStore` is the production one.
public protocol PinnedListDownloadStoring: Sendable {
  func pinnedKeys(accountID: Int64) async -> Set<LibraryCollectionKey>
  func pin(accountID: Int64, key: LibraryCollectionKey, at date: Date) async throws
  func unpin(accountID: Int64, key: LibraryCollectionKey) async throws -> [PinnedListMember]
  @discardableResult func dropVanishedPins(accountID: Int64) async throws -> Int
  func pruneDeclines(accountID: Int64) async throws
  func candidates(accountID: Int64, limit: Int) async throws -> [PinnedListCandidate]
  func recordClaim(
    accountID: Int64, key: LibraryCollectionKey, member: PinnedListMember, at date: Date
  ) async throws
  func releasableClaims(accountID: Int64) async throws -> [PinnedListClaim]
  func dropClaim(accountID: Int64, claim: PinnedListClaim) async throws
  func isKeptBesidesPins(
    accountID: Int64, member: PinnedListMember, excluding: LibraryCollectionKey?
  ) async throws -> Bool
  func claimedMembers(accountID: Int64, key: LibraryCollectionKey) async throws -> [PinnedListMember]
}

extension PinnedListStore: PinnedListDownloadStoring {}

/// The download intents a pin needs: audio requests, audio-only releases, and the low-disk pause.
public protocol PinnedListDownloadRequesting: Sendable {
  func requestDownload(itemID: String) async throws
  func requestEpisodeDownload(itemID: String, episodeID: String) async throws
  func purgeItemAudioDownload(itemID: String, source: DownloadPurgeSource) async throws
  func purgeEpisodeDownload(itemID: String, episodeID: String, source: DownloadPurgeSource) async throws
  func isQueuePausedForLowDisk() async -> Bool
}

extension DownloadCoordinator: PinnedListDownloadRequesting {}

// MARK: - Reconciler

/// Keeps pinned collections and playlists downloaded. Each pass releases what members that left
/// a list no longer need, then requests up to `maxRequestsPerPass` members with no audio row.
/// Concurrent callers share one in-flight pass.
///
/// A request returns nothing, so creation is inferred: a candidate had no audio row, so a request
/// that did not throw created one, and the pin claims it. Releases check every other reason to
/// keep a download themselves, since the purge path checks none.
public actor PinnedListDownloadReconciler: CoalescedPassHost {
  /// Matches `PodcastAutoDownloadPolicy.maxEpisodesPerPass`. Each book request costs an
  /// item-detail fetch; the rest wait for the next pass.
  static let maxRequestsPerPass = 20

  private let accountID: Int64
  private let store: any PinnedListDownloadStoring
  private let requesting: any PinnedListDownloadRequesting
  private let diagnostics: any DiagnosticsRecording
  private let now: @Sendable () -> Date

  /// Members whose request failed for a reason another try cannot fix. Process-lifetime only, so
  /// a relaunch tries them once more.
  private var refused: Set<PinnedListMember> = []

  var passSlot = CoalescedPassSlot<Void>()
  var joinedFlightCount: Int { passSlot.joinedCount }

  public init(
    accountID: Int64,
    store: any PinnedListDownloadStoring,
    requesting: any PinnedListDownloadRequesting,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.accountID = accountID
    self.store = store
    self.requesting = requesting
    self.diagnostics = diagnostics
    self.now = now
  }

  /// Runs one pass. Concurrent callers coalesce onto the same in-flight pass.
  public func run() async {
    await runCoalescedPass(policy: .shareInFlight) { await self.perform() }
  }

  /// Pins the list and runs a pass at once, so its members start downloading.
  public func pin(_ key: LibraryCollectionKey) async throws {
    try await store.pin(accountID: accountID, key: key, at: now())
    await run()
  }

  /// How many downloads `unpin` would delete: this pin's claims that nothing else keeps.
  public func downloadsUnpinningWouldRemove(_ key: LibraryCollectionKey) async throws -> Int {
    var count = 0
    for member in try await store.claimedMembers(accountID: accountID, key: key) {
      if try await store.isKeptBesidesPins(accountID: accountID, member: member, excluding: key) == false {
        count += 1
      }
    }
    return count
  }

  /// Removes the pin and deletes the audio its own requests downloaded, unless something else
  /// still keeps it.
  public func unpin(_ key: LibraryCollectionKey) async throws {
    for member in try await store.unpin(accountID: accountID, key: key) {
      guard try await store.isKeptBesidesPins(accountID: accountID, member: member, excluding: nil) == false
      else { continue }
      try? await release(member)
    }
  }

  private func perform() async {
    guard await store.pinnedKeys(accountID: accountID).isEmpty == false else { return }
    let startedAt = now()
    var failureCount = 0
    do {
      try await store.dropVanishedPins(accountID: accountID)
      try await store.pruneDeclines(accountID: accountID)
    } catch {
      failureCount += 1
    }
    failureCount += await releaseLeftMembers()
    // Releasing frees space, so only requests wait out a low-disk pause.
    if await requesting.isQueuePausedForLowDisk() == false {
      failureCount += await requestCandidates()
    }
    await recordDiagnostic(failed: failureCount > 0, startedAt: startedAt)
  }

  private func releaseLeftMembers() async -> Int {
    guard let claims = try? await store.releasableClaims(accountID: accountID) else { return 1 }
    var failureCount = 0
    for claim in claims {
      guard Task.isCancelled == false else { break }
      do {
        // A claim something else still keeps stays, so it is released once nothing does.
        guard
          try await store.isKeptBesidesPins(accountID: accountID, member: claim.member, excluding: nil)
            == false
        else { continue }
        try await release(claim.member)
        try await store.dropClaim(accountID: accountID, claim: claim)
      } catch {
        failureCount += 1
      }
    }
    return failureCount
  }

  private func requestCandidates() async -> Int {
    let limit = Self.maxRequestsPerPass + refused.count
    guard let candidates = try? await store.candidates(accountID: accountID, limit: limit) else {
      return 1
    }
    var failureCount = 0
    for candidate in candidates.filter({ refused.contains($0.member) == false })
      .prefix(Self.maxRequestsPerPass)
    {
      guard Task.isCancelled == false else { break }
      do {
        if let episodeID = candidate.member.serverEpisodeID {
          try await requesting.requestEpisodeDownload(
            itemID: candidate.member.serverItemID, episodeID: episodeID)
        } else {
          try await requesting.requestDownload(itemID: candidate.member.serverItemID)
        }
        try await store.recordClaim(
          accountID: accountID, key: candidate.key, member: candidate.member, at: now())
      } catch {
        failureCount += 1
        if Self.isPermanent(error) { refused.insert(candidate.member) }
      }
    }
    return failureCount
  }

  private func release(_ member: PinnedListMember) async throws {
    if let episodeID = member.serverEpisodeID {
      try await requesting.purgeEpisodeDownload(
        itemID: member.serverItemID, episodeID: episodeID, source: .pinnedListRelease)
    } else {
      try await requesting.purgeItemAudioDownload(
        itemID: member.serverItemID, source: .pinnedListRelease)
    }
  }

  /// Failures that say the member itself cannot be downloaded. Network, sign-in and account
  /// removal failures are not about the member.
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
    await diagnostics.record(
      DiagnosticsEvent(
        category: .download, statusClass: failed ? .clientError : .success,
        durationMilliseconds: SyncEngine.durationMilliseconds(startedAt: startedAt, endedAt: now())),
      accountId: accountID)
  }
}
