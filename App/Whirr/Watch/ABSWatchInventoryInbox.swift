import Foundation
import Persistence
import WatchProtocol

/// Applies the Audiobookshelf half of one `WatchEpisodeInventory` for the bound account
/// (ADR 0021).
///
/// `WatchEpisodeInventoryInbox` decodes the inventory once and hands it here whatever the RSS half
/// did, and the store keeps its own sequence, so one half can never starve the other. Entries are
/// read only when the Watch stamped them with this phone's account: a Watch signed out,
/// or on another account, is reported as a mismatch and nothing else in its entries is used.
@MainActor
final class ABSWatchInventoryInbox {
  /// What the Watch's latest Audiobookshelf report said about its account.
  enum AccountMatch: Equatable {
    case matching
    /// The Watch reported Audiobookshelf entries under another account, or none.
    case mismatch
  }

  private let store: ABSWatchCopyStore
  private let stamp: WatchAccountStamp
  private let resolver: ABSWatchTitleResolver
  private let record: ABSWatchInventoryRecord
  /// The applied snapshot, already saved to the record when this fires.
  var onApplied: @MainActor (ABSWatchInventoryRecord.Snapshot) -> Void = { _ in }
  var onAccountMatch: @MainActor (AccountMatch) -> Void = { _ in }

  init(
    store: ABSWatchCopyStore, stamp: WatchAccountStamp, resolver: ABSWatchTitleResolver,
    record: ABSWatchInventoryRecord
  ) {
    self.store = store
    self.stamp = stamp
    self.resolver = resolver
    self.record = record
  }

  /// Returns the store's outcome, or nil when the inventory carried no Audiobookshelf half for this
  /// account. An inventory with no `absEntries` key comes from a Watch that predates Audiobookshelf
  /// sends, and says nothing about its account.
  @discardableResult
  func receive(_ inventory: WatchEpisodeInventory, now: Date) async -> ABSWatchCopyInventoryOutcome? {
    guard let wireEntries = inventory.absEntries else { return nil }
    guard inventory.absAccountStamp == stamp else {
      onAccountMatch(.mismatch)
      return nil
    }
    onAccountMatch(.matching)
    let known = Set(((try? await store.copies()) ?? []).map(\.key))
    var entries: [ABSWatchInventory.Entry] = []
    var groups: [ABSWatchGroup] = []
    for wire in wireEntries {
      let key = ABSWatchCopyKey(itemId: wire.selection.itemID, episodeId: wire.selection.episodeID)
      let revision = Self.revision(wire)
      // Titles are read only where they will be shown: a Watch-origin row, or a phone-origin row
      // this phone lost and is about to re-adopt.
      let facts = revision == nil || known.contains(key) == false ? await resolver.titles(key) : nil
      if let revision {
        entries.append(
          ABSWatchInventory.Entry(
            key: key, revision: revision, state: Self.storeState(wire.state),
            declineReason: Self.declineReason(wire.declineReason),
            failureReason: Self.failureReason(wire.failureReason),
            committedBytes: wire.committedBytes, title: facts?.title ?? "",
            subtitle: facts?.subtitle))
      }
      groups.append(Self.group(wire, key: key, revision: revision, facts: facts))
    }
    let mapped = ABSWatchInventory(
      watchInstallID: inventory.watchInstallID, sequence: inventory.sequence,
      accountIdentityHash: stamp.accountIdentityHash,
      acknowledgedGeneration: inventory.absAcknowledgedGeneration ?? 0, entries: entries)
    guard let outcome = try? await store.applyInventory(mapped, now: now) else { return nil }
    // A late or repeated sequence must not replace the live projection, exactly as the store's own
    // sequence check keeps it out of the database.
    if outcome.applied {
      let snapshot = ABSWatchInventoryRecord.Snapshot(
        watchInstallID: inventory.watchInstallID, accountIdentityHash: stamp.accountIdentityHash,
        groups: groups)
      record.save(snapshot)
      onApplied(snapshot)
    }
    return outcome
  }

  /// A phone-origin group names the revision it was sent at. The wire allows a revision on a
  /// Watch-origin entry only to ignore it, and one past the store's range is not this phone's.
  private static func revision(_ entry: WatchABSInventoryEntry) -> Int64? {
    guard entry.origin == .phone, let revision = entry.revision, revision > 0,
      revision <= UInt64(Int64.max)
    else { return nil }
    return Int64(revision)
  }

  private static func group(
    _ wire: WatchABSInventoryEntry, key: ABSWatchCopyKey, revision: Int64?,
    facts: ABSWatchTitleFacts?
  ) -> ABSWatchGroup {
    ABSWatchGroup(
      itemID: key.itemId, episodeID: key.episodeId, revision: revision,
      state: groupState(wire.state), progress: wire.progress, trackCount: wire.trackCount,
      completedTracks: wire.completedTracks, committedBytes: wire.committedBytes,
      declineReason: declineReason(wire.declineReason),
      failureReason: failureReason(wire.failureReason),
      title: facts?.title ?? "", subtitle: facts?.subtitle)
  }

  static func storeState(_ state: WatchABSInventoryEntry.State) -> ABSWatchInventory.Entry.State {
    switch state {
    case .receiving, .downloading, .waitingForNetwork: .receiving
    case .ready: .ready
    case .removed: .removed
    case .declined: .declined
    case .failed: .failed
    }
  }

  static func groupState(_ state: WatchABSInventoryEntry.State) -> ABSWatchGroup.State {
    switch state {
    case .receiving: .queued
    case .downloading: .downloading
    case .waitingForNetwork: .waitingForNetwork
    case .ready: .ready
    case .failed: .failed
    case .declined: .declined
    case .removed: .removed
    }
  }

  static func declineReason(_ reason: WatchABSInventoryEntry.DeclineReason?) -> RSSWatchDeclineReason? {
    switch reason {
    case .storageFull: .storageFull
    case .invalid: .invalid
    case .signedOut: .signedOut
    case nil: nil
    }
  }

  static func failureReason(_ reason: WatchABSInventoryEntry.FailureReason?) -> ABSWatchFailureReason? {
    switch reason {
    case .httpStatus: .httpStatus
    case .insecureRedirect: .insecureRedirect
    case .tooLarge: .tooLarge
    case .invalidResponse: .invalidResponse
    case .network: .network
    case .itemMissing: .itemMissing
    case .noAudio: .noAudio
    case .planInvalid: .planInvalid
    case nil: nil
    }
  }
}
