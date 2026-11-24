import Foundation
import WatchProtocol

public enum WatchABSOfferAcceptance: Sendable, Equatable {
  public enum IgnoredReason: String, Sendable, Equatable {
    case foreignAccount
    case foreignInstall
    case staleGeneration
  }

  case accepted
  case ignored(IgnoredReason)
}

/// One step that brings the Watch's Audiobookshelf downloads into line with the phone's set.
public enum WatchABSRequestAction: Sendable, Equatable {
  /// Plan the entry and enqueue whatever of it the store does not hold yet.
  case fetch(WatchABSOfferEntry)
  /// Re-admit a failed, declined or held group, as the wrist's Retry does.
  case retry(WatchABSOfferEntry)
  /// Make an existing group the phone's, at this revision.
  case adopt(WatchABSSelection, revision: UInt64)
  /// Delete the group through the controller's delete, which stops its playback first.
  case remove(WatchABSSelection)
}

public struct WatchABSReconcilePlan: Sendable, Equatable {
  /// The offer generation to acknowledge once every action has run; `nil` with no offer.
  public let generation: UInt64?
  /// Removals first, because they free space; then the phone's entries in its priority order.
  public let actions: [WatchABSRequestAction]
}

/// The Watch's record of the phone's Audiobookshelf requests for one account: the last offer, the
/// generation acknowledged, failures before any file was enqueued, and phone-sent groups the
/// listener removed on the Watch (ADR 0021). The download store remains the truth about
/// files; this holds only what the store cannot.
///
/// The Watch persists the offer and reconciles it on arrival, on a refresh wake and when the
/// account becomes ready, so a launch too short to plan a book loses nothing.
public struct WatchABSRequestLedger: Codable, Sendable, Equatable {
  public struct Record: Codable, Sendable, Equatable {
    public let selection: WatchABSSelection
    public let revision: UInt64
    public let outcome: WatchABSRequestOutcome
  }

  /// A phone-origin group the listener removed on the Watch. It is reported as `removed` until the
  /// phone omits the selection or sends it at a higher revision.
  public struct Tombstone: Codable, Sendable, Equatable {
    public let selection: WatchABSSelection
    public let revision: UInt64
  }

  public private(set) var offer: WatchABSSendOffer?
  public private(set) var acknowledgedGeneration: UInt64 = 0
  public private(set) var outcomes: [Record] = []
  public private(set) var tombstones: [Tombstone] = []

  public init() {}

  public mutating func accept(
    _ offer: WatchABSSendOffer, installID: String, accountStamp: WatchAccountStamp
  ) -> WatchABSOfferAcceptance {
    guard offer.accountStamp == accountStamp else { return .ignored(.foreignAccount) }
    if let offered = offer.watchInstallID, offered != installID { return .ignored(.foreignInstall) }
    guard offer.generation > max(self.offer?.generation ?? 0, acknowledgedGeneration) else {
      return .ignored(.staleGeneration)
    }
    self.offer = offer
    return .accepted
  }

  /// What to do about `groups`, the signed-in account's Audiobookshelf groups, given the last offer.
  ///
  /// - Omission removes only phone-origin groups, and only from an offer that names a matching
  ///   inventory: a phone that lost its rows must not delete the Watch's copies.
  /// - Explicit removals apply once per generation, and spare a group created after the offer was
  ///   sent: the phone repeats a removal until it is acknowledged, and the listener may have
  ///   downloaded the item again on the wrist since.
  /// - A failure before enqueue waits for a new revision, or for the network when it was one
  ///   (`retryNetworkFailures`).
  public mutating func reconcile(
    groups: [WatchDownloadGroup], retryNetworkFailures: Bool = false
  ) -> WatchABSReconcilePlan {
    guard let offer else { return WatchABSReconcilePlan(generation: nil, actions: []) }
    let held = Self.bySelection(groups)
    prune(against: offer, held: held)

    var actions: [WatchABSRequestAction] = []
    var removing: Set<WatchABSSelection> = []
    func remove(_ selection: WatchABSSelection) {
      if removing.insert(selection).inserted { actions.append(.remove(selection)) }
    }
    if offer.generation > acknowledgedGeneration {
      for selection in offer.removals {
        if let group = held[selection], group.createdAt <= offer.sentAt { remove(selection) }
      }
    }
    if offer.inventorySequence != nil {
      let wanted = Set(offer.entries.map(\.selection))
      for group in groups where group.origin == .phone {
        guard let selection = Self.absSelection(group), wanted.contains(selection) == false else { continue }
        remove(selection)
      }
    }
    for entry in offer.entries {
      actions += self.actions(for: entry, group: held[entry.selection], retryNetworkFailures: retryNetworkFailures)
    }
    return WatchABSReconcilePlan(generation: offer.generation, actions: actions)
  }

  public mutating func markApplied(generation: UInt64) {
    acknowledgedGeneration = max(acknowledgedGeneration, generation)
  }

  /// Remembers a failure before enqueue for this revision, replacing any earlier one.
  public mutating func record(_ outcome: WatchABSRequestOutcome, for selection: WatchABSSelection, revision: UInt64) {
    outcomes.removeAll { $0.selection == selection }
    outcomes.append(Record(selection: selection, revision: revision, outcome: outcome))
  }

  public mutating func clearOutcome(for selection: WatchABSSelection) {
    outcomes.removeAll { $0.selection == selection }
  }

  /// Call when the listener deletes a group on the Watch. Only a phone-origin group leaves a
  /// tombstone; a deletion the phone asked for leaves none.
  public mutating func recordRemoval(of group: WatchDownloadGroup) {
    guard group.origin == .phone, let revision = group.phoneRevision, revision > 0,
      let selection = Self.absSelection(group)
    else { return }
    tombstones.removeAll { $0.selection == selection }
    tombstones.append(Tombstone(selection: selection, revision: revision))
    clearOutcome(for: selection)
  }

  /// The Audiobookshelf half of the inventory: every group of either origin, then the phone's
  /// requests that have no group: removed on the Watch, refused before enqueue, or not yet planned.
  public func inventoryEntries(groups: [WatchDownloadGroup]) -> [WatchABSInventoryEntry] {
    var entries: [WatchABSInventoryEntry] = []
    var named: Set<WatchABSSelection> = []
    func add(_ entry: WatchABSInventoryEntry?) {
      guard let entry, named.insert(entry.selection).inserted else { return }
      entries.append(entry)
    }
    for group in groups { add(try? WatchABSInventoryProjection.entry(for: group)) }
    for tombstone in tombstones {
      let entry = try? WatchABSInventoryEntry(
        selection: tombstone.selection, revision: tombstone.revision, origin: .phone, state: .removed,
        trackCount: 0, completedTracks: 0)
      add(entry)
    }
    for record in outcomes {
      let entry: WatchABSInventoryEntry?
      switch record.outcome {
      case .failed(let reason):
        entry = try? WatchABSInventoryEntry(
          selection: record.selection, revision: record.revision, origin: .phone, state: .failed, trackCount: 0,
          completedTracks: 0, failureReason: reason)
      case .declined(let reason):
        entry = try? WatchABSInventoryEntry(
          selection: record.selection, revision: record.revision, origin: .phone, state: .declined,
          trackCount: 0, completedTracks: 0, declineReason: reason)
      }
      add(entry)
    }
    for offered in offer?.entries ?? [] {
      let entry = try? WatchABSInventoryEntry(
        selection: offered.selection, revision: offered.revision, origin: .phone, state: .receiving, trackCount: 0,
        completedTracks: 0)
      add(entry)
    }
    return entries
  }

  // MARK: Rules

  private func actions(
    for entry: WatchABSOfferEntry, group: WatchDownloadGroup?, retryNetworkFailures: Bool
  ) -> [WatchABSRequestAction] {
    if let group {
      let owned = group.origin == .phone ? group.phoneRevision ?? 0 : 0
      guard owned <= entry.revision else { return [] }
      guard owned < entry.revision else { return group.state == .enqueuing ? [.fetch(entry)] : [] }
      // A wrist download the phone now asks for, or the phone's Try Again on its own group.
      var actions: [WatchABSRequestAction] = [.adopt(entry.selection, revision: entry.revision)]
      switch group.state {
      case .failed, .declined, .waitingForNetwork: actions.append(.retry(entry))
      case .enqueuing: actions.append(.fetch(entry))
      case .waiting, .downloading, .ready: break
      }
      return actions
    }
    if let tombstone = tombstones.first(where: { $0.selection == entry.selection }),
      tombstone.revision >= entry.revision
    {
      return []
    }
    if let record = outcomes.first(where: { $0.selection == entry.selection }), record.revision >= entry.revision {
      return retryNetworkFailures && record.outcome.retriesWhenTheNetworkReturns ? [.fetch(entry)] : []
    }
    return [.fetch(entry)]
  }

  /// Forgets what the offer has moved past: a selection it no longer names, a revision it has
  /// raised, and anything a group now stands for.
  private mutating func prune(against offer: WatchABSSendOffer, held: [WatchABSSelection: WatchDownloadGroup]) {
    let revisions = Dictionary(offer.entries.map { ($0.selection, $0.revision) }, uniquingKeysWith: max)
    outcomes.removeAll { record in
      held[record.selection] != nil || (revisions[record.selection].map { $0 > record.revision } ?? true)
    }
    tombstones.removeAll { tombstone in
      held[tombstone.selection] != nil || (revisions[tombstone.selection].map { $0 > tombstone.revision } ?? true)
    }
  }

  private static func bySelection(_ groups: [WatchDownloadGroup]) -> [WatchABSSelection: WatchDownloadGroup] {
    var result: [WatchABSSelection: WatchDownloadGroup] = [:]
    for group in groups {
      guard let selection = absSelection(group), result[selection] == nil else { continue }
      result[selection] = group
    }
    return result
  }

  private static func absSelection(_ group: WatchDownloadGroup) -> WatchABSSelection? {
    try? WatchABSSelection(selection: group.selection)
  }
}

extension WatchABSRequestOutcome: Codable {
  private enum CodingKeys: String, CodingKey { case failureReason, declineReason }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let reason = try container.decodeIfPresent(WatchABSInventoryEntry.DeclineReason.self, forKey: .declineReason) {
      self = .declined(reason)
    } else {
      self = .failed(try container.decode(WatchABSInventoryEntry.FailureReason.self, forKey: .failureReason))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .failed(let reason): try container.encode(reason, forKey: .failureReason)
    case .declined(let reason): try container.encode(reason, forKey: .declineReason)
    }
  }
}
