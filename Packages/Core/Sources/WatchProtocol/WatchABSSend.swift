import Foundation

/// Caps for the phone's desired set of Audiobookshelf books and episodes (ADR 0021 Decision 9).
public enum WatchABSSendLimits {
  /// Entries and removals together. The inventory applies the same 100 across its RSS and
  /// Audiobookshelf halves (`WatchEpisodeSendLimits.maxInventoryEntries`).
  public static let maxOfferRows = WatchProtocolVersion.maxRows
  /// Equal to the RSS offer's. A title and a subtitle may each take 512 bytes, so 100 entries can
  /// exceed it, and `WatchABSSendOffer.fitting` trims the tail.
  public static let maxOfferWireBytes = 64 * 1024
  /// A sanity bound on a declared or committed size, not a budget: a book larger than the Watch's
  /// storage is a real request the Watch declines, so the wire must carry it. 1 TiB is beyond any
  /// audiobook.
  public static let maxItemBytes: Int64 = 1 << 40
  /// A sanity bound on one group's audio files. Books with hundreds of files exist; ten thousand
  /// do not.
  public static let maxTrackCount = 10_000
}

extension WatchABSSelection {
  /// `WatchABSSelection` throws `WatchHandoffError` for the handoff keys. On the send keys the
  /// Watch's ingress handles one error type, so the send values map it here.
  func validateForSend() throws {
    do {
      try validate()
    } catch {
      throw WatchProtocolCodingError.invalidSelection
    }
  }
}

/// One book or Audiobookshelf podcast episode in the phone's desired set. It carries display text
/// and an optional size and position only: the Watch plans the files from its own `detail()` call,
/// with its own sign-in, so no URL, token or file list crosses the link (ADR 0021 Decision 1).
public struct WatchABSOfferEntry: Codable, Sendable, Equatable {
  public let selection: WatchABSSelection
  /// Increments each time the phone sends the selection afresh, so the Watch can tell a new send
  /// (a Try Again) from a repeat of one it already holds or already failed.
  public let revision: UInt64
  public let title: String
  /// The author or the show, when there is one.
  public let subtitle: String?
  /// The phone's estimate of the audio's size, for its own "Waiting for space" copy. The Watch
  /// admits against the plan from `detail()`, never against this.
  public let declaredBytes: Int64?
  /// The phone's position at the time of the offer, when it has one.
  public let position: Double?

  public init(
    selection: WatchABSSelection, revision: UInt64, title: String, subtitle: String?,
    declaredBytes: Int64?, position: Double?
  ) throws {
    self.selection = selection
    self.revision = revision
    self.title = title
    self.subtitle = subtitle
    self.declaredBytes = declaredBytes
    self.position = position
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      selection: container.decode(WatchABSSelection.self, forKey: .selection),
      revision: container.decode(UInt64.self, forKey: .revision),
      title: container.decode(String.self, forKey: .title),
      subtitle: container.decodeIfPresent(String.self, forKey: .subtitle),
      declaredBytes: container.decodeIfPresent(Int64.self, forKey: .declaredBytes),
      position: container.decodeIfPresent(Double.self, forKey: .position))
  }

  public func validate() throws {
    try selection.validateForSend()
    guard revision > 0 else { throw WatchProtocolCodingError.invalidValue }
    try WatchEpisodeSendValidation.metadata(title)
    if let subtitle { try WatchEpisodeSendValidation.metadata(subtitle) }
    if let declaredBytes {
      guard declaredBytes > 0, declaredBytes <= WatchABSSendLimits.maxItemBytes else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
    if let position { try WatchEpisodeSendValidation.position(position) }
  }

  private enum CodingKeys: String, CodingKey {
    case selection, revision, title, subtitle, declaredBytes, position
  }
}

/// The phone's whole desired set of Audiobookshelf selections for one account, not a delta, plus
/// the Watch-origin downloads the listener asked the phone to remove (ADR 0021 Decisions 1 and 4).
/// Omission removes only a phone-origin group; a Watch-origin group goes only through `removals`.
public struct WatchABSSendOffer: WatchWireValue, Equatable {
  public static let transportKey = WatchTransportKey.absSendOffer
  public static let maxWireBytes = WatchABSSendLimits.maxOfferWireBytes
  public let version: Int
  /// Monotonic per phone install, counted apart from the RSS offer's generation. 0 is reserved for
  /// "no offer applied yet" in `WatchEpisodeInventory.absAcknowledgedGeneration`.
  public let generation: UInt64
  /// As on the RSS offer: `nil` before the phone has seen an inventory, and otherwise the Watch
  /// ignores an offer for another install.
  public let watchInstallID: String?
  /// The phone's authenticated account. The Watch ignores an offer whose stamp is not its own
  /// (ADR 0021 Decision 5).
  public let accountStamp: WatchAccountStamp
  /// In the phone's priority order; `fitting` trims from the tail.
  public let entries: [WatchABSOfferEntry]
  /// Selections the phone's set never contained that the listener removed from the phone. The
  /// phone keeps each one here until an inventory acknowledges the generation and omits it.
  public let removals: [WatchABSSelection]
  public let sentAt: Date
  /// The `sequence` of the last inventory the phone applied whose `absAccountStamp` matched this
  /// offer's account; `nil` when it has applied none. The Watch removes nothing by omission from an
  /// offer without one, so a phone that lost its rows (a sign-out, a reinstall) cannot delete the
  /// Watch's phone-sent groups with an empty set before it has re-adopted them.
  public let inventorySequence: UInt64?

  public init(
    generation: UInt64, watchInstallID: String?, accountStamp: WatchAccountStamp,
    entries: [WatchABSOfferEntry], removals: [WatchABSSelection], sentAt: Date,
    inventorySequence: UInt64? = nil
  ) throws {
    self.version = WatchProtocolVersion.current
    self.generation = generation
    self.watchInstallID = watchInstallID
    self.accountStamp = accountStamp
    self.entries = entries
    self.removals = removals
    self.sentAt = sentAt
    self.inventorySequence = inventorySequence
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    guard generation > 0 else { throw WatchProtocolCodingError.invalidValue }
    if let watchInstallID { try WatchInstallIdentity.validate(watchInstallID) }
    try accountStamp.validate()
    guard entries.count + removals.count <= WatchABSSendLimits.maxOfferRows else {
      throw WatchProtocolCodingError.tooManyRows
    }
    for entry in entries { try entry.validate() }
    for removal in removals { try removal.validateForSend() }
    let wanted = Set(entries.map(\.selection))
    let removed = Set(removals)
    guard wanted.count == entries.count, removed.count == removals.count, wanted.isDisjoint(with: removed)
    else { throw WatchProtocolCodingError.invalidValue }
    try WatchEpisodeSendValidation.date(sentAt)
    // The exact byte cap is the codec's, because only the encoder knows the metadata cost.
  }

  /// Keeps the longest leading run of `removals`, then of `entries`, whose encoding fits
  /// `maxWireBytes`, and returns what it left out of each. Removals go first because they free
  /// space on the Watch. The whole set is validated first: a duplicate or an impossible value is a
  /// caller bug, not something to drop silently as "did not fit".
  public static func fitting(
    generation: UInt64, watchInstallID: String?, accountStamp: WatchAccountStamp,
    entries: [WatchABSOfferEntry], removals: [WatchABSSelection], sentAt: Date,
    inventorySequence: UInt64? = nil
  ) throws -> (offer: WatchABSSendOffer, omitted: [WatchABSSelection], omittedRemovals: [WatchABSSelection]) {
    func make(_ entries: ArraySlice<WatchABSOfferEntry>, _ removals: ArraySlice<WatchABSSelection>) throws
      -> WatchABSSendOffer
    {
      try WatchABSSendOffer(
        generation: generation, watchInstallID: watchInstallID, accountStamp: accountStamp,
        entries: Array(entries), removals: Array(removals), sentAt: sentAt,
        inventorySequence: inventorySequence)
    }
    func fits(_ offer: WatchABSSendOffer) -> Bool { (try? WatchWireCodec.encode(offer)) != nil }

    _ = try make(entries[...], removals[...])
    var keptRemovals = 0
    while keptRemovals < removals.count, fits(try make([], removals.prefix(keptRemovals + 1))) {
      keptRemovals += 1
    }
    let removalRun = removals.prefix(keptRemovals)
    var keptEntries = 0
    while keptEntries < entries.count, fits(try make(entries.prefix(keptEntries + 1), removalRun)) {
      keptEntries += 1
    }
    return (
      try make(entries.prefix(keptEntries), removalRun),
      entries.dropFirst(keptEntries).map(\.selection),
      Array(removals.dropFirst(keptRemovals))
    )
  }
}

/// Who started an Audiobookshelf download group on the Watch (ADR 0021 Decision 3).
public enum WatchABSOrigin: String, Codable, Sendable, Equatable {
  /// Started from the Watch itself. The phone never removes it by omission and never adopts it.
  case watch
  /// Started by a phone offer. A later offer from the same account removes it by omitting it.
  case phone
}

/// One Audiobookshelf group the Watch holds, is fetching, failed or declined, from either origin.
/// It shares the RSS entry's state, decline and failure vocabularies, and their per-state rules, so
/// the phone has one mapping to its statuses. A book is one entry, however many files it has.
public struct WatchABSInventoryEntry: Codable, Sendable, Equatable {
  public typealias State = WatchEpisodeInventoryEntry.State
  public typealias DeclineReason = WatchEpisodeInventoryEntry.DeclineReason
  public typealias FailureReason = WatchEpisodeInventoryEntry.FailureReason

  public let selection: WatchABSSelection
  /// The phone revision a phone-origin group answers; `nil` for a Watch-origin group.
  public let revision: UInt64?
  public let origin: WatchABSOrigin
  public let state: State
  /// The group's audio files, once the Watch has planned it; 0 before then, as for a failure
  /// before enqueue.
  public let trackCount: Int
  public let completedTracks: Int
  /// Present iff `state == .declined`.
  public let declineReason: DeclineReason?
  /// Present iff `state == .failed`.
  public let failureReason: FailureReason?
  /// Present only while `.downloading`, and only when known: the fraction across all the group's
  /// files, weighted by bytes.
  public let progress: Double?
  /// Present iff `state == .ready`; the group's bytes against the Watch's shared budget.
  public let committedBytes: Int64?

  public init(
    selection: WatchABSSelection, revision: UInt64?, origin: WatchABSOrigin, state: State, trackCount: Int,
    completedTracks: Int, declineReason: DeclineReason? = nil, failureReason: FailureReason? = nil,
    progress: Double? = nil, committedBytes: Int64? = nil
  ) throws {
    self.selection = selection
    self.revision = revision
    self.origin = origin
    self.state = state
    self.trackCount = trackCount
    self.completedTracks = completedTracks
    self.declineReason = declineReason
    self.failureReason = failureReason
    self.progress = progress
    self.committedBytes = committedBytes
    try validate()
  }

  /// Tolerant on purpose, as `WatchEpisodeInventoryEntry` is: a value this build does not know must
  /// not cost the phone the rest of the inventory. An unknown origin reads as `.watch`, the reading
  /// under which the phone can never remove the group by omission, and so drops its revision.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state =
      (try? container.decode(String.self, forKey: .state)).flatMap(State.init(rawValue:)) ?? .receiving
    let origin =
      (try? container.decode(String.self, forKey: .origin)).flatMap(WatchABSOrigin.init(rawValue:)) ?? .watch
    let decodedProgress = try? container.decodeIfPresent(Double.self, forKey: .progress)
    let progress = decodedProgress.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    let decodedFailure = try? container.decodeIfPresent(String.self, forKey: .failureReason)
    try self.init(
      selection: container.decode(WatchABSSelection.self, forKey: .selection),
      revision: origin == .phone ? container.decodeIfPresent(UInt64.self, forKey: .revision) : nil,
      origin: origin,
      state: state,
      trackCount: container.decodeIfPresent(Int.self, forKey: .trackCount) ?? 0,
      completedTracks: container.decodeIfPresent(Int.self, forKey: .completedTracks) ?? 0,
      declineReason: container.decodeIfPresent(DeclineReason.self, forKey: .declineReason),
      failureReason: state == .failed
        ? (decodedFailure.flatMap(FailureReason.init(rawValue:)) ?? .invalidResponse) : nil,
      progress: state == .downloading ? progress : nil,
      committedBytes: container.decodeIfPresent(Int64.self, forKey: .committedBytes))
  }

  public func validate() throws {
    try selection.validateForSend()
    switch origin {
    case .phone: guard let revision, revision > 0 else { throw WatchProtocolCodingError.invalidValue }
    case .watch: guard revision == nil else { throw WatchProtocolCodingError.invalidValue }
    }
    guard (0...WatchABSSendLimits.maxTrackCount).contains(trackCount),
      (0...trackCount).contains(completedTracks)
    else { throw WatchProtocolCodingError.invalidValue }
    try validateStateFields()
  }

  private func validateStateFields() throws {
    let valid: Bool
    switch state {
    case .declined:
      valid = declineReason != nil && committedBytes == nil && progress == nil && failureReason == nil
    case .ready:
      valid =
        declineReason == nil && progress == nil && failureReason == nil
        && trackCount > 0 && completedTracks == trackCount
        && committedBytes.map { $0 > 0 && $0 <= WatchABSSendLimits.maxItemBytes } == true
    case .downloading:
      valid =
        declineReason == nil && committedBytes == nil && failureReason == nil
        && (progress.map { $0.isFinite && (0...1).contains($0) } ?? true)
    case .failed:
      valid = failureReason != nil && declineReason == nil && committedBytes == nil && progress == nil
    case .receiving, .waitingForNetwork, .removed:
      valid = declineReason == nil && committedBytes == nil && progress == nil && failureReason == nil
    }
    guard valid else { throw WatchProtocolCodingError.invalidValue }
  }

  private enum CodingKeys: String, CodingKey {
    case selection, revision, origin, state, trackCount, completedTracks, declineReason, failureReason,
      progress, committedBytes
  }
}
