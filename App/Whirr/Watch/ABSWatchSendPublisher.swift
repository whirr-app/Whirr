import Foundation
import Persistence
import WatchProtocol

/// Sends the bound account's desired set of Audiobookshelf titles to the active Watch and keeps it
/// in step (ADR 0021).
///
/// Unlike the RSS sender it is account-bound: composed with the account and stopped with it, and
/// every offer carries the account's authenticated stamp. It sends nothing for an account until the
/// store holds an inventory stamped with it, because the first offer after a re-sign-in
/// would otherwise list an empty set and remove every phone-sent title by omission. Each offer also
/// names the sequence of that inventory, and the Watch removes nothing by omission from one without.
///
/// The offer names titles only. The Watch plans the files from its own `detail()` call, with its own
/// credential; no URL, token or file list leaves the phone.
@MainActor
final class ABSWatchSendPublisher {
  struct Sender {
    var isWatchInstalled: @MainActor () -> Bool
    /// Queues the encoded offer over `transferUserInfo`; the Watch answers with an inventory.
    var sendOffer: @MainActor (Data) -> Bool
  }

  private struct SentOffer: Equatable {
    let watchInstallID: String?
    let generation: UInt64
    let entries: [WatchABSOfferEntry]
    let removals: [WatchABSSelection]
  }

  private let store: ABSWatchCopyStore
  private let stamp: WatchAccountStamp
  /// The phone's stored progress for a title, for the finished-title check.
  private let progress: @MainActor (ABSWatchCopyKey) -> StoredAudioProgress?
  private let sender: Sender
  private let now: @MainActor () -> Date
  private let removesFinished: @MainActor () -> Bool
  private let coalescer: WatchSendCoalescer

  private var lastSentOffer: SentOffer?

  init(
    store: ABSWatchCopyStore, stamp: WatchAccountStamp,
    progress: @escaping @MainActor (ABSWatchCopyKey) -> StoredAudioProgress?, sender: Sender,
    now: @escaping @MainActor () -> Date = { Date() },
    debounce: Duration = WatchEpisodeSendPublisher.defaultDebounce,
    removesFinished: @escaping @MainActor () -> Bool = { true }
  ) {
    self.store = store
    self.stamp = stamp
    self.progress = progress
    self.sender = sender
    self.now = now
    self.removesFinished = removesFinished
    self.coalescer = WatchSendCoalescer(debounce: debounce)
  }

  /// Coalesced planning. The bind, an applied inventory, the install state, the Settings toggle and
  /// the model's own writes all call this.
  func refresh() {
    coalescer.schedule { [weak self] token in
      await self?.runRefresh(token: token)
    }
  }

  /// The Watch app was installed again: an offer the old install never read must be sent anew.
  func watchBecameAvailable() {
    lastSentOffer = nil
    refresh()
  }

  /// The account unbound: nothing more leaves for it.
  func stop() {
    coalescer.stop()
  }

  /// Waits for the pending planning pass; tests observe the result through it.
  func settle() async {
    await coalescer.settle()
  }

  // MARK: - Planning

  private func runRefresh(token: Int) async {
    guard !coalescer.isStopped, coalescer.isCurrent(token),
      var set = try? await store.setState(),
      set.inventoryAccountHash == stamp.accountIdentityHash,
      var rows = try? await store.copies()
    else { return }
    let now = self.now()
    if removesFinished(), await removeFinished(rows, now: now) {
      guard let reloadedRows = try? await store.copies(), let reloadedSet = try? await store.setState()
      else { return }
      rows = reloadedRows
      set = reloadedSet
    }
    guard !coalescer.isStopped, coalescer.isCurrent(token) else { return }
    sendIfNewer(offer(rows: rows, set: set, now: now), acknowledged: set.acknowledgedGeneration)
  }

  /// A phone-sent title leaves the Watch once the phone records it finished after the
  /// request, so a deliberate re-send of a finished book stays. Watch-origin downloads have no row
  /// here and are never removed this way. Returns whether any row changed.
  private func removeFinished(_ rows: [ABSWatchCopy], now: Date) async -> Bool {
    var changed = false
    for row in rows where [.wanted, .waitingForWatch, .sending, .delivered].contains(row.state) {
      guard let stored = progress(row.key), stored.isFinished,
        let changedAt = stored.changedAt, changedAt > row.requestedAt
      else { continue }
      _ = try? await store.removeFromWatch(row.key, title: row.title, subtitle: row.subtitle, now: now)
      changed = true
    }
    return changed
  }

  /// The whole desired set as one offer, newest request first, trimmed from the tail only by the
  /// wire caps. A failed row stays a member at its revision: the Watch retries it only when Try
  /// Again requests a new one.
  private func offer(rows: [ABSWatchCopy], set: ABSWatchCopySetState, now: Date) -> WatchABSSendOffer? {
    guard set.generation > 0 else { return nil }
    var entries: [WatchABSOfferEntry] = []
    var removals: [WatchABSSelection] = []
    for row in rows {
      if row.removalGeneration != nil, let selection = Self.selection(row.key) {
        removals.append(selection)
      } else if let entry = Self.entry(row) {
        entries.append(entry)
      }
    }
    let boundedRemovals = Array(removals.prefix(WatchABSSendLimits.maxOfferRows))
    let boundedEntries = Array(entries.prefix(WatchABSSendLimits.maxOfferRows - boundedRemovals.count))
    return try? WatchABSSendOffer.fitting(
      generation: UInt64(clamping: set.generation), watchInstallID: set.watchInstallID,
      accountStamp: stamp, entries: boundedEntries, removals: boundedRemovals, sentAt: now,
      inventorySequence: UInt64(clamping: set.inventorySequence)
    ).offer
  }

  /// The Watch applies a generation at most once, so an unchanged one is not queued again.
  private func sendIfNewer(_ offer: WatchABSSendOffer?, acknowledged: Int64) {
    guard let offer, sender.isWatchInstalled(), offer.generation > UInt64(clamping: acknowledged)
    else { return }
    let sent = SentOffer(
      watchInstallID: offer.watchInstallID, generation: offer.generation, entries: offer.entries,
      removals: offer.removals)
    guard sent != lastSentOffer, let data = try? WatchWireCodec.encode(offer), sender.sendOffer(data)
    else { return }
    lastSentOffer = sent
  }

  // MARK: - Offer entries

  static func selection(_ key: ABSWatchCopyKey) -> WatchABSSelection? {
    try? WatchABSSelection(itemID: key.itemId, episodeID: key.episodeId)
  }

  /// A member's entry, or nil for a row that is not a member (removed, declined) or that the wire
  /// cannot carry. A size the wire would refuse is sent as unknown.
  static func entry(_ row: ABSWatchCopy) -> WatchABSOfferEntry? {
    guard row.state != .removed, row.state != .declined, row.revision > 0,
      let selection = selection(row.key)
    else { return nil }
    let declared = row.declaredBytes.flatMap {
      $0 > 0 && $0 <= WatchABSSendLimits.maxItemBytes ? $0 : nil
    }
    let fallback = row.key.episodeId == nil ? "Audiobook" : "Episode"
    return try? WatchABSOfferEntry(
      selection: selection, revision: UInt64(row.revision),
      title: wireText(row.title) ?? fallback, subtitle: row.subtitle.flatMap(wireText),
      declaredBytes: declared, position: nil)
  }

  /// Library text as the wire takes it: control characters folded to spaces, anything that reads
  /// as a path or URL dropped, and the length bounded. Nil when nothing usable is left.
  static func wireText(_ value: String) -> String? {
    var result = value.components(separatedBy: .controlCharacters).joined(separator: " ")
      .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    if result.contains("://") || result.lowercased().hasPrefix("file:") || result.hasPrefix("/") {
      return nil
    }
    while result.utf8.count > WatchProtocolVersion.maxMetadataStringBytes {
      result.removeLast()
    }
    return result.isEmpty ? nil : result
  }
}
