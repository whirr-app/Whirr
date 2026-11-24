import Foundation
import Persistence
import WatchProtocol

/// What the Watch's latest inventory said about one copy's own download. The persisted row is the
/// durable state, while a percentage and a network hold are live facts the screen reads until the
/// next report. `WatchDownloadStatusRecord` keeps the latest projection across this
/// phone's relaunch, so the raw values are part of that stored shape.
struct WatchEpisodeDownloadStatus: Codable, Equatable, Sendable {
  /// The in-progress wire states, in the phone's own terms so screens never switch over a wire
  /// type. A finished, removed or declined copy has no download status.
  enum State: String, Codable, Equatable, Sendable {
    case queued
    case downloading
    case waitingForNetwork
    case failed
  }

  let revision: Int64
  let state: State
  let progress: Double?
}

/// Applies one `WatchEpisodeInventory` to the phone's desired set.
///
/// The wire names episodes by `(feedID, identityKey)`, while the store works in `rssEpisode` row
/// ids. The mapping happens here, once per feed and in batches, and an entry naming a feed or an
/// episode the phone no longer has is dropped: a feed unfollowed (or an episode pruned) since the
/// offer is not an error, and the Watch's next inventory simply omits the copy. Only a report about
/// a row the phone still has can move it.
///
/// The store's inventory states are the phone's terms for the Watch's own download: `downloading`
/// and `waitingForNetwork` become its one in-progress state, and a `failed` download becomes the
/// store's retryable failure through a transition.
@MainActor
final class WatchEpisodeInventoryInbox {
  typealias EpisodeIDLookup =
    @MainActor (_ feedId: Int64, _ identityKeys: [String]) async -> [String: Int64]

  private let copies: RSSWatchCopyStore
  private let record: WatchDownloadStatusRecord
  private let episodeIDs: EpisodeIDLookup
  /// The publisher re-offers after an inventory: the Watch asking for what it lacks is the only
  /// recovery path for a wiped or interrupted copy.
  var onApplied: @MainActor (RSSWatchCopyInventoryOutcome) -> Void = { _ in }
  /// The whole download projection, replaced on each newer inventory. The inbox has already saved
  /// it to its record when this fires.
  var onStatuses: @MainActor ([Int64: WatchEpisodeDownloadStatus]) -> Void = { _ in }
  /// The Audiobookshelf half, handed the decoded inventory before the RSS half applies, whatever
  /// that half does (ADR 0021). Each half keeps its own sequence, so neither can starve the other.
  var onABSInventory: @MainActor (WatchEpisodeInventory, Date) async -> Void = { _, _ in }

  init(
    copies: RSSWatchCopyStore,
    record: WatchDownloadStatusRecord,
    episodeIDs: @escaping EpisodeIDLookup
  ) {
    self.copies = copies
    self.record = record
    self.episodeIDs = episodeIDs
  }

  /// Rejects an oversized or undecodable payload, maps what it can, and applies the result. The
  /// phone's own `now` is the store's write time and the inventory's observed time, so ordering
  /// never depends on the Watch's clock; `sequence` remains the dedup key for one install.
  @discardableResult
  func receive(_ data: Data, now: Date) async -> RSSWatchCopyInventoryOutcome? {
    guard data.count <= WatchEpisodeInventory.maxWireBytes,
      let inventory = try? WatchWireCodec.decode(WatchEpisodeInventory.self, from: data)
    else { return nil }
    await onABSInventory(inventory, now)

    let idsByKey = await resolveEpisodeIDs(for: inventory.entries)
    var entries: [RSSWatchInventory.Entry] = []
    var failures: [(episodeId: Int64, revision: Int64)] = []
    var statuses: [Int64: WatchEpisodeDownloadStatus] = [:]
    entries.reserveCapacity(inventory.entries.count)
    for entry in inventory.entries {
      guard let feedID = Int64(entry.selection.feedID), feedID > 0,
        entry.revision <= UInt64(Int64.max),
        let episodeId = idsByKey[FeedKey(feedId: feedID, identityKey: entry.selection.episodeID)]
      else { continue }
      let revision = Int64(entry.revision)
      if entry.state == .failed {
        failures.append((episodeId: episodeId, revision: revision))
      } else if let state = Self.storeState(entry.state) {
        entries.append(
          RSSWatchInventory.Entry(
            episodeId: episodeId, revision: revision, state: state,
            declineReason: Self.declineReason(entry.declineReason),
            committedBytes: entry.committedBytes))
      }
      if let status = Self.downloadStatus(entry) {
        statuses[episodeId] = status
      }
    }

    let mapped = RSSWatchInventory(
      watchInstallID: inventory.watchInstallID, sequence: inventory.sequence,
      acknowledgedGeneration: inventory.acknowledgedGeneration,
      acceptsCopies: inventory.acceptsCopies, entries: entries,
      budgetTotalBytes: inventory.budgetTotalBytes, budgetUsedBytes: inventory.budgetUsedBytes,
      observedAt: now)
    // Read before applying: a late duplicate must not overwrite the live projection, exactly as the
    // store's own sequence check keeps it out of the database.
    let previous = try? await copies.setState()
    guard let outcome = try? await copies.applyInventory(mapped, now: now) else { return nil }
    let isNewer =
      previous?.watchInstallID != inventory.watchInstallID
      || (previous?.inventorySequence ?? 0) < inventory.sequence
    if isNewer {
      for failure in failures {
        await applyFailure(
          episodeId: failure.episodeId, revision: failure.revision, now: now)
      }
      // Saved before it is published, so a relaunch can only restore a projection the screen was
      // already showing. An empty projection is the newest answer and must overwrite the old one.
      record.save(watchInstallID: inventory.watchInstallID, statuses: statuses)
      onStatuses(statuses)
    }
    onApplied(outcome)
    return outcome
  }

  private func resolveEpisodeIDs(
    for entries: [WatchEpisodeInventoryEntry]
  ) async -> [FeedKey: Int64] {
    var keysByFeed: [Int64: [String]] = [:]
    for entry in entries {
      guard let feedID = Int64(entry.selection.feedID), feedID > 0 else { continue }
      keysByFeed[feedID, default: []].append(entry.selection.episodeID)
    }
    var ids: [FeedKey: Int64] = [:]
    for (feedID, identityKeys) in keysByFeed {
      let found = await episodeIDs(feedID, identityKeys)
      for (identityKey, episodeId) in found {
        ids[FeedKey(feedId: feedID, identityKey: identityKey)] = episodeId
      }
    }
    return ids
  }

  /// The store's inventory states cannot name a failed download, so a failure is applied as the
  /// retryable `failed` transition. A row that never reported `receiving` is still `wanted`, which
  /// is one step further back than the transition allows; it moves through `sending`, the state a
  /// Watch-side failure is reachable from.
  private func applyFailure(episodeId: Int64, revision: Int64, now: Date) async {
    if (try? await copies.transition(
      episodeId: episodeId, revision: revision, to: .failed, now: now)) == true
    {
      return
    }
    guard
      (try? await copies.transition(
        episodeId: episodeId, revision: revision, to: .sending, now: now)) == true
    else { return }
    _ = try? await copies.transition(
      episodeId: episodeId, revision: revision, to: .failed, now: now)
  }

  private static func storeState(
    _ state: WatchEpisodeInventoryEntry.State
  ) -> RSSWatchInventory.Entry.State? {
    switch state {
    case .ready: .ready
    case .receiving, .downloading, .waitingForNetwork: .receiving
    case .removed: .removed
    case .declined: .declined
    case .failed: nil
    }
  }

  private static func downloadStatus(
    _ entry: WatchEpisodeInventoryEntry
  ) -> WatchEpisodeDownloadStatus? {
    let state: WatchEpisodeDownloadStatus.State
    switch entry.state {
    case .receiving: state = .queued
    case .downloading: state = .downloading
    case .waitingForNetwork: state = .waitingForNetwork
    case .failed: state = .failed
    case .ready, .removed, .declined: return nil
    }
    return WatchEpisodeDownloadStatus(
      revision: Int64(entry.revision), state: state, progress: entry.progress)
  }

  private static func declineReason(
    _ reason: WatchEpisodeInventoryEntry.DeclineReason?
  ) -> RSSWatchDeclineReason? {
    switch reason {
    case .storageFull: .storageFull
    case .invalid: .invalid
    case .signedOut: .signedOut
    case nil: nil
    }
  }

  private struct FeedKey: Hashable {
    let feedId: Int64
    let identityKey: String
  }
}
