import ABSApi
import AppModel
import Foundation
import Observation
import Persistence

/// One Audiobookshelf title the On Apple Watch screen can show: a row of the bound account's
/// desired set, or a download the Watch started itself.
struct ABSWatchCopyRow: Identifiable, Equatable, Sendable {
  let key: ABSWatchCopyKey
  let title: String
  /// The author of a book, or the show of an episode.
  let subtitle: String?
  let state: WatchCopyState
  /// The phone's revision; nil for a download the Watch started itself.
  let revision: Int64?
  /// The Watch's latest report on this group, when it reported on the row's own revision.
  let group: ABSWatchGroup?
  /// Nil for a download the Watch started itself.
  let requestedAt: Date?
  /// The item's cover, from the library; nil when it no longer holds the item.
  var artwork: ABSWatchArtwork? = nil

  var id: String { "abs:\(key.itemId)/\(key.episodeId ?? "")" }
  var isBook: Bool { key.episodeId == nil }
  var isPhoneOrigin: Bool { revision != nil }
}

/// The App's read of the Audiobookshelf half of Send to Watch for the bound account (ADR 0021):
/// the account's `absWatchCopy` rows, the Watch-origin downloads from the last applied
/// inventory, and whether the Watch can take an offer from this phone at all.
///
/// Unlike `WatchEpisodeCopiesModel` it follows the account: `WatchCompanionRuntime`, which owns it,
/// binds it with the account's store and unbinds it with the account graph, so nothing from one
/// account is shown under another. Every write goes through the store and then asks the publisher
/// to plan.
@MainActor
@Observable
final class ABSWatchCopiesModel {
  /// Phone rows newest request first, then the Watch's own downloads in its order.
  private(set) var rows: [ABSWatchCopyRow] = []
  private(set) var setState = ABSWatchCopySetState()
  /// From the Watch's status report, through the setup model.
  private(set) var readiness: WatchABSReadiness = .unknown
  /// From the Watch's latest inventory: nil until one with an Audiobookshelf half arrives.
  private(set) var inventoryMatch: ABSWatchInventoryInbox.AccountMatch?
  private(set) var isBound = false

  @ObservationIgnored private var store: ABSWatchCopyStore?
  @ObservationIgnored private var resolver: ABSWatchTitleResolver?
  @ObservationIgnored private var refreshOffer: @MainActor () -> Void = {}
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var copies: [ABSWatchCopy] = []
  @ObservationIgnored private var groups: [ABSWatchGroup] = []
  /// One library read per item for each bind, not per rebuild.
  @ObservationIgnored private var artworkByItem: [String: ABSWatchArtwork?] = [:]

  // MARK: - Lifecycle

  /// Binds the account's store. The Watch's own report arrives through `applyInventory`, from the
  /// saved record at launch and from each applied inventory after.
  func bind(
    store: ABSWatchCopyStore, resolver: ABSWatchTitleResolver,
    refreshOffer: @escaping @MainActor () -> Void
  ) {
    unbind()
    self.store = store
    self.resolver = resolver
    self.refreshOffer = refreshOffer
    isBound = true
    observationTask = Task { @MainActor [weak self] in
      for await observation in store.observe() {
        guard !Task.isCancelled, let self else { return }
        self.apply(observation)
      }
    }
  }

  func unbind() {
    observationTask?.cancel()
    observationTask = nil
    store = nil
    resolver = nil
    refreshOffer = {}
    copies = []
    groups = []
    artworkByItem = [:]
    if rows.isEmpty == false { rows = [] }
    if setState != ABSWatchCopySetState() { setState = ABSWatchCopySetState() }
    if inventoryMatch != nil { inventoryMatch = nil }
    if isBound { isBound = false }
  }

  func applyReadiness(_ readiness: WatchABSReadiness) {
    if readiness != self.readiness { self.readiness = readiness }
  }

  func applyInventoryMatch(_ match: ABSWatchInventoryInbox.AccountMatch) {
    if match != inventoryMatch { inventoryMatch = match }
  }

  /// Replaces the Watch's report with a newer applied inventory's.
  func applyInventory(_ snapshot: ABSWatchInventoryRecord.Snapshot) {
    guard isBound else { return }
    groups = snapshot.groups
    rebuild()
  }

  // MARK: - Reads

  /// Readiness with the inventory's own account fact: an inventory stamped with another account, or
  /// none, means the Watch needs setting up for this one.
  var effectiveReadiness: WatchABSReadiness {
    guard readiness != .notInstalled else { return .notInstalled }
    return inventoryMatch == .mismatch ? .setUpWatch : readiness
  }

  /// What the screen lists: nothing while the Watch is signed out or on another account.
  var visibleRows: [ABSWatchCopyRow] {
    effectiveReadiness == .setUpWatch || effectiveReadiness == .notInstalled ? [] : rows
  }

  /// Whether the menus offer Send and Remove for Audiobookshelf titles. A Watch never heard from
  /// still gets them, and its rows say "Open Whirr on your Watch"; one that predates Audiobookshelf
  /// sends, or is on another account, would never act on them.
  var offersWatchActions: Bool {
    isBound && (effectiveReadiness == .ready || effectiveReadiness == .unknown)
  }

  /// The Watch's free space from its last inventory, or nil before it has reported one.
  var freeBytes: Int64? {
    guard let total = setState.budgetTotalBytes, let used = setState.budgetUsedBytes else { return nil }
    return max(total - used, 0)
  }

  /// The title's copy, from its row or from a download the Watch started itself.
  func copyState(_ key: ABSWatchCopyKey) -> WatchCopyState? {
    row(key)?.state
  }

  /// The title's row. A Watch-origin row is listed only when no standing phone row shadows it, so
  /// where both exist it is the newer fact: a wrist download after the phone's acknowledged removal.
  func row(_ key: ABSWatchCopyKey) -> ABSWatchCopyRow? {
    guard isBound else { return nil }
    let matching = rows.filter { $0.key == key }
    return matching.first { $0.isPhoneOrigin == false } ?? matching.first
  }

  /// The canonical menu's answer, or nil to hide both Watch entries.
  func watchCopy(_ key: ABSWatchCopyKey) -> PodcastEpisodeWatchCopy? {
    guard offersWatchActions else { return nil }
    return copyState(key)?.menuCopy ?? .notOnWatch
  }

  /// What the phone's library says about a title, for the size check before a send.
  func facts(_ key: ABSWatchCopyKey) async -> ABSWatchTitleFacts? {
    await resolver?.facts(key)
  }

  /// A book whose known size exceeds the Watch's last reported free space, with both
  /// figures, or nil to send at once. An unknown size, or no inventory yet, never asks.
  func oversizedBook(itemID: String) -> ABSWatchOversizedSend? {
    guard let resolver else { return nil }
    return Self.oversized(declared: resolver.bookFacts(itemID)?.declaredBytes, free: freeBytes)
  }

  static func oversized(declared: Int64?, free: Int64?) -> ABSWatchOversizedSend? {
    guard let declared, let free, declared > free else { return nil }
    return ABSWatchOversizedSend(declaredBytes: declared, freeBytes: free)
  }

  // MARK: - Actions

  /// Sends one title, or sends a failed or removed one again at a new revision.
  func send(_ key: ABSWatchCopyKey) async {
    guard let store, let resolver else { return }
    let facts = await resolver.titles(key)
    _ = try? await store.request(
      key, title: facts.title, subtitle: facts.subtitle, declaredBytes: facts.declaredBytes,
      now: Date())
    refreshOffer()
  }

  /// Removes one title from the Watch, whoever started its download.
  func remove(_ key: ABSWatchCopyKey) async {
    guard let store else { return }
    let known = rows.first { $0.key == key }
    let facts: ABSWatchTitleFacts
    if let known {
      facts = ABSWatchTitleFacts(title: known.title, subtitle: known.subtitle, declaredBytes: nil)
    } else if let resolver {
      facts = await resolver.titles(key)
    } else {
      return
    }
    _ = try? await store.removeFromWatch(key, title: facts.title, subtitle: facts.subtitle, now: Date())
    refreshOffer()
  }

  // MARK: - Projection

  private func apply(_ observation: ABSWatchCopyObservation) {
    copies = observation.copies
    if setState != observation.set { setState = observation.set }
    rebuild()
  }

  private func rebuild() {
    let built = Self.rows(copies: copies, groups: groups) { self.artwork(itemID: $0) }
    if built != rows { rows = built }
  }

  private func artwork(itemID: String) -> ABSWatchArtwork? {
    if let known = artworkByItem[itemID] { return known }
    let resolved = resolver?.artwork(itemID: itemID)
    artworkByItem[itemID] = resolved
    return resolved
  }

  /// Phone rows first, newest request first, then each Watch-origin download the phone has no
  /// standing row for. A Watch-origin download the listener removed here is left out until the
  /// Watch drops it; one downloaded again on the wrist after that removal is shown again.
  static func rows(
    copies: [ABSWatchCopy], groups: [ABSWatchGroup],
    artwork: (String) -> ABSWatchArtwork? = { _ in nil }
  ) -> [ABSWatchCopyRow] {
    var shadowed: Set<ABSWatchCopyKey> = []
    var result: [ABSWatchCopyRow] = []
    for copy in copies {
      if copy.state != .removed || copy.removalGeneration != nil { shadowed.insert(copy.key) }
      let group = groups.first { $0.key == copy.key && $0.revision == copy.revision }
      result.append(
        ABSWatchCopyRow(
          key: copy.key, title: copy.title, subtitle: copy.subtitle, state: WatchCopyState(copy),
          revision: copy.revision, group: group, requestedAt: copy.requestedAt,
          artwork: artwork(copy.key.itemId)))
    }
    for group in groups where group.isPhoneOrigin == false && shadowed.contains(group.key) == false {
      guard let state = group.copyState else { continue }
      result.append(
        ABSWatchCopyRow(
          key: group.key, title: group.title.isEmpty ? Self.placeholder(group.key) : group.title,
          subtitle: group.subtitle, state: state, revision: nil, group: group, requestedAt: nil,
          artwork: artwork(group.itemID)))
    }
    return result
  }

  private static func placeholder(_ key: ABSWatchCopyKey) -> String {
    key.episodeId == nil ? "Audiobook" : "Episode"
  }
}
