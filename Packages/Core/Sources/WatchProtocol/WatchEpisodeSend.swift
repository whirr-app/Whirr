import Foundation

/// Caps for sending a downloaded native-RSS episode from the phone to the Watch.
public enum WatchEpisodeSendLimits {
  /// The catalogue row cap. The Watch's 2 GB budget holds roughly 25 episodes, so 100 is headroom
  /// for a long desired set, not a target; the offer still fits only what its byte cap allows.
  public static let maxOfferEntries = WatchProtocolVersion.maxRows
  /// `transferUserInfo` payloads are small by contract. An offer carries titles, positions, the
  /// enclosure URL and its chapters, never audio, and is sent on its own key so it never queues
  /// behind anything else.
  public static let maxOfferWireBytes = 64 * 1024
  /// An inventory names one entry per copy the Watch holds, wants, removed or declined. Its RSS
  /// `entries` and Audiobookshelf `absEntries` count together against this one cap (ADR 0021
  /// Decision 9).
  public static let maxInventoryEntries = WatchProtocolVersion.maxRows
  /// Equal to the offer cap, but no longer implied by it: the inventory also lists Audiobookshelf
  /// groups, including ones started on the Watch that no offer named, so the Watch trims to fit
  /// (`WatchEpisodeInventoryPlan`). An entry is at most about 1.1 KB with the longest identifiers,
  /// and well under 200 bytes with real ones, so a 100-entry inventory fits unless its identifiers
  /// are pathological. A trimmed phone-origin entry reads as lost and is offered again, which is
  /// harmless; a trimmed Watch-origin one leaves the phone's list until the next inventory.
  public static let maxInventoryWireBytes = 64 * 1024
  /// Bounds decode work and the offer's chapter payload. Podcasts with more chapters than this are
  /// rare, and a longer list would not fit the offer cap with realistic titles anyway.
  public static let maxChapters = 200
  /// Matches `RSSFileStore.sizeCapBytes` (Persistence/RSSFileStore.swift:64), the absolute cap on
  /// every RSS enclosure. `WatchProtocol` cannot import `Persistence`, so the value is repeated
  /// here and the two must change together.
  public static let maxEpisodeBytes: Int64 = 1 << 30
  /// A MIME type is `type/subtype` plus parameters; 128 bytes covers every audio type the phone
  /// serves without giving feed text unbounded room on the wire.
  public static let maxMimeTypeBytes = 128
  /// One enclosure URL, as the Watch will request it. Long enough for the signed CDN URLs podcast
  /// hosts hand out, short enough that one entry cannot spend a useful share of the offer cap.
  public static let maxEnclosureURLBytes = 2048
}

/// The one rule for the enclosure URL an offer carries (ADR 0020 Decision 1). Every other string
/// field on the wire refuses a URL; this typed field is the sanctioned exception, because the Watch
/// downloads the enclosure itself rather than receiving the phone's file. Only what a background
/// `URLSession` can actually fetch is accepted: an absolute `http`/`https` URL with a host and no
/// embedded credentials.
public enum WatchEnclosureURL {
  public static func validate(_ url: URL) throws {
    let text = url.absoluteString
    guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil
    else { throw WatchProtocolCodingError.invalidValue }
    guard text.utf8.count <= WatchEpisodeSendLimits.maxEnclosureURLBytes else {
      throw WatchProtocolCodingError.oversizedMetadata
    }
  }

  public static func isValid(_ url: URL) -> Bool {
    (try? validate(url)) != nil
  }
}

/// A Watch install identity, stable for the lifetime of the Watch app's installation. It is a
/// canonical UUID string, lowercase and hyphenated (`UUID().uuidString.lowercased()`; the bare
/// `uuidString` is uppercase and is rejected), so both devices compare the same text rather than
/// two spellings of one UUID.
public enum WatchInstallIdentity {
  public static func validate(_ id: String) throws {
    guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

/// Identifier and metadata rules shared by the send values. They mirror the rules
/// `WatchCatalogueItem` applies to titles, so a feed string is bounded the same way on both keys.
enum WatchEpisodeSendValidation {
  static func metadata(_ value: String) throws {
    guard !value.isEmpty,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw WatchProtocolCodingError.invalidValue }
    guard !value.contains("://"), !value.lowercased().hasPrefix("file:"), !value.hasPrefix("/") else {
      throw WatchProtocolCodingError.forbiddenMetadata
    }
    guard value.utf8.count <= WatchProtocolVersion.maxMetadataStringBytes else {
      throw WatchProtocolCodingError.oversizedMetadata
    }
  }

  static func mimeType(_ value: String) throws {
    guard !value.isEmpty,
      value.utf8.count <= WatchEpisodeSendLimits.maxMimeTypeBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { throw WatchProtocolCodingError.invalidValue }
  }

  /// A feed's position may sit beyond the episode's own duration (a stale duration), so only the
  /// handoff ceiling bounds it.
  static func position(_ value: Double) throws {
    guard value.isFinite, value >= 0, value <= WatchHandoffLimits.maxPositionSeconds else {
      throw WatchProtocolCodingError.invalidValue
    }
  }

  static func duration(_ value: Double) throws {
    guard value.isFinite, value > 0, value <= WatchHandoffLimits.maxPositionSeconds else {
      throw WatchProtocolCodingError.invalidValue
    }
  }

  static func date(_ value: Date) throws {
    guard value.timeIntervalSinceReferenceDate.isFinite else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

/// A native-feed episode named across the phone/Watch boundary. RSS episodes have their own type
/// so a send value can never name an Audiobookshelf title by accident.
public struct WatchNativeSelection: Codable, Sendable, Hashable {
  public let feedID: String
  public let episodeID: String

  public init(feedID: String, episodeID: String) throws {
    self.feedID = feedID
    self.episodeID = episodeID
    try validate()
  }

  /// Only a `.nativeFeed` selection can be named; an Audiobookshelf title has `WatchABSSelection`.
  public init?(_ selection: WatchSelection) {
    guard case .nativeFeed(let feedID, let episodeID) = selection else { return nil }
    self.feedID = feedID
    self.episodeID = episodeID
  }

  public var selection: WatchSelection { .nativeFeed(feedID: feedID, episodeID: episodeID) }

  /// Delegates to `WatchSelection` so both directions of the wire apply one identifier rule.
  public func validate() throws {
    try selection.validate()
  }

  private enum CodingKeys: String, CodingKey { case feedID, episodeID }
}

/// One chapter of a sent episode. `end` is absent when the feed gives only a start; the Watch then
/// treats the chapter as running to the next one, as the phone does.
public struct WatchEpisodeChapter: Codable, Sendable, Equatable {
  public let title: String
  public let start: Double
  public let end: Double?

  public init(title: String, start: Double, end: Double? = nil) throws {
    self.title = title
    self.start = start
    self.end = end
    try validate()
  }

  public func validate() throws {
    try WatchEpisodeSendValidation.metadata(title)
    try WatchEpisodeSendValidation.position(start)
    if let end {
      guard end.isFinite, end > start, end <= WatchHandoffLimits.maxPositionSeconds else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
  }
}

/// One episode in the phone's desired set. `revision` increments each time the phone offers the
/// episode afresh, so the Watch can tell a new send from a repeat of one it already holds.
public struct WatchEpisodeOfferEntry: Codable, Sendable, Equatable {
  public let selection: WatchNativeSelection
  public let revision: UInt64
  public let title: String
  public let showTitle: String
  public let duration: Double?
  /// The length the feed declared, when it declared one. It is a reservation estimate only and
  /// never bounds the download: a host that inserts ads changes the real length (ADR 0020
  /// Decision 2).
  public let declaredBytes: Int64?
  /// Where the Watch downloads the audio itself. Deliberately a URL: this typed field is the one
  /// place the wire carries one, because the Watch fetches the enclosure instead of receiving the
  /// phone's file (ADR 0020 Decision 1).
  public let enclosureURL: URL
  public let mimeType: String
  /// The episode's chapters, in non-decreasing `start` order. They ride the offer because no file
  /// arrives with them attached any more (ADR 0020 Decision 1).
  public let chapters: [WatchEpisodeChapter]
  /// The phone's own position for the episode at the time of the offer; the Watch starts here so
  /// the two devices agree before the first Watch listen.
  public let position: Double
  public let lastListenedAt: Date?

  public init(
    selection: WatchNativeSelection, revision: UInt64, title: String, showTitle: String, duration: Double?,
    declaredBytes: Int64?, enclosureURL: URL, mimeType: String, chapters: [WatchEpisodeChapter] = [],
    position: Double, lastListenedAt: Date?
  ) throws {
    self.selection = selection
    self.revision = revision
    self.title = title
    self.showTitle = showTitle
    self.duration = duration
    self.declaredBytes = declaredBytes
    self.enclosureURL = enclosureURL
    self.mimeType = mimeType
    self.chapters = chapters
    self.position = position
    self.lastListenedAt = lastListenedAt
    try validate()
  }

  /// A phone that predates chapters sends none, and one that predates the declared length sends a
  /// set without it; both are complete enough for the Watch to fetch the episode.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      selection: container.decode(WatchNativeSelection.self, forKey: .selection),
      revision: container.decode(UInt64.self, forKey: .revision),
      title: container.decode(String.self, forKey: .title),
      showTitle: container.decode(String.self, forKey: .showTitle),
      duration: container.decodeIfPresent(Double.self, forKey: .duration),
      declaredBytes: container.decodeIfPresent(Int64.self, forKey: .declaredBytes),
      enclosureURL: container.decode(URL.self, forKey: .enclosureURL),
      mimeType: container.decode(String.self, forKey: .mimeType),
      chapters: container.decodeIfPresent([WatchEpisodeChapter].self, forKey: .chapters) ?? [],
      position: container.decode(Double.self, forKey: .position),
      lastListenedAt: container.decodeIfPresent(Date.self, forKey: .lastListenedAt))
  }

  public func validate() throws {
    try selection.validate()
    guard revision > 0 else { throw WatchProtocolCodingError.invalidValue }
    try WatchEpisodeSendValidation.metadata(title)
    try WatchEpisodeSendValidation.metadata(showTitle)
    if let duration { try WatchEpisodeSendValidation.duration(duration) }
    if let declaredBytes {
      guard declaredBytes > 0, declaredBytes <= WatchEpisodeSendLimits.maxEpisodeBytes else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
    try WatchEnclosureURL.validate(enclosureURL)
    try WatchEpisodeSendValidation.mimeType(mimeType)
    guard chapters.count <= WatchEpisodeSendLimits.maxChapters else {
      throw WatchProtocolCodingError.tooManyRows
    }
    var previousStart = -Double.infinity
    for chapter in chapters {
      try chapter.validate()
      guard chapter.start >= previousStart else { throw WatchProtocolCodingError.invalidValue }
      previousStart = chapter.start
    }
    try WatchEpisodeSendValidation.position(position)
    if let lastListenedAt { try WatchEpisodeSendValidation.date(lastListenedAt) }
  }

  private enum CodingKeys: String, CodingKey {
    case selection, revision, title, showTitle, duration, declaredBytes, enclosureURL, mimeType,
      chapters, position, lastListenedAt
  }
}

/// The phone's whole desired set for the active Watch, not a delta: the Watch reconciles what it
/// holds against it, so a lost offer or a wiped Watch recovers from the next one. The Watch owns
/// its inventory and is the only side that says a copy is ready.
public struct WatchEpisodeSendOffer: WatchWireValue, Equatable {
  public static let transportKey = WatchTransportKey.episodeSendOffer
  public static let maxWireBytes = WatchEpisodeSendLimits.maxOfferWireBytes
  public let version: Int
  /// Monotonic per phone install. A generation the Watch has already applied is ignored.
  public let generation: UInt64
  /// The Watch install the phone last saw in an inventory; `nil` before it has seen one. The Watch
  /// accepts `nil` or its own ID and ignores the offer otherwise, which is how a new install
  /// replaces the previous Watch's set rather than inheriting it.
  public let watchInstallID: String?
  /// In the phone's priority order; `fitting` trims from the tail.
  public let entries: [WatchEpisodeOfferEntry]
  public let sentAt: Date

  public init(
    generation: UInt64, watchInstallID: String?, entries: [WatchEpisodeOfferEntry], sentAt: Date
  ) throws {
    self.version = WatchProtocolVersion.current
    self.generation = generation
    self.watchInstallID = watchInstallID
    self.entries = entries
    self.sentAt = sentAt
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    // `WatchEpisodeInventory.acknowledgedGeneration` reserves 0 for "no offer applied yet".
    guard generation > 0 else { throw WatchProtocolCodingError.invalidValue }
    if let watchInstallID { try WatchInstallIdentity.validate(watchInstallID) }
    guard entries.count <= WatchEpisodeSendLimits.maxOfferEntries else {
      throw WatchProtocolCodingError.tooManyRows
    }
    guard Set(entries.map(\.selection)).count == entries.count else {
      throw WatchProtocolCodingError.invalidValue
    }
    for entry in entries { try entry.validate() }
    try WatchEpisodeSendValidation.date(sentAt)
    // The exact byte cap is the codec's, because only the encoder knows the metadata cost.
  }

  /// Keeps the longest leading run of `entries` whose encoding fits `maxWireBytes` and returns the
  /// rest, so the phone can still show those as waiting. Ordering is the phone's priority order.
  /// The whole set is validated first: a duplicate or an impossible entry is a caller bug, not
  /// something to silently drop as "did not fit".
  public static func fitting(
    generation: UInt64, watchInstallID: String?, entries: [WatchEpisodeOfferEntry], sentAt: Date
  ) throws -> (offer: WatchEpisodeSendOffer, omitted: [WatchNativeSelection]) {
    _ = try WatchEpisodeSendOffer(
      generation: generation, watchInstallID: watchInstallID, entries: entries, sentAt: sentAt)
    var kept = 0
    while kept < entries.count {
      let candidate = try WatchEpisodeSendOffer(
        generation: generation, watchInstallID: watchInstallID,
        entries: Array(entries.prefix(kept + 1)), sentAt: sentAt)
      guard (try? WatchWireCodec.encode(candidate)) != nil else { break }
      kept += 1
    }
    let offer = try WatchEpisodeSendOffer(
      generation: generation, watchInstallID: watchInstallID, entries: Array(entries.prefix(kept)),
      sentAt: sentAt)
    return (offer, entries.dropFirst(kept).map(\.selection))
  }
}

/// One episode the Watch holds, is receiving, is downloading, failed, removed or declined. A
/// `removed` entry is a tombstone: the Watch keeps it until the phone's next generation
/// acknowledges the removal, so a re-offer of the same revision cannot resurrect the copy.
public struct WatchEpisodeInventoryEntry: Codable, Sendable, Equatable {
  public enum State: String, Codable, Sendable, Equatable {
    /// Admitted and queued; the download has not started.
    case receiving
    case downloading
    case waitingForNetwork = "waiting_for_network"
    case ready
    case failed
    case removed
    case declined
  }

  /// Why the Watch would not accept a copy. Fixed cases, because each drives different phone copy.
  public enum DeclineReason: String, Codable, Sendable, Equatable {
    case storageFull = "storage_full"
    case invalid
    case signedOut = "signed_out"
  }

  /// Why the Watch's own download did not produce a playable copy (ADR 0020 Decisions 2–4). The
  /// last three are failures before any file is queued for an Audiobookshelf send; an
  /// older phone never sees them, because it ignores `absEntries`.
  public enum FailureReason: String, Codable, Sendable, Equatable, Error {
    case httpStatus = "http_status"
    case insecureRedirect = "insecure_redirect"
    case tooLarge = "too_large"
    case invalidResponse = "invalid_response"
    case network
    /// The server no longer has the item or episode.
    case itemMissing = "item_missing"
    /// The item has no audio the Watch can play.
    case noAudio = "no_audio"
    /// The item's audio files could not be planned into a download.
    case planInvalid = "plan_invalid"
  }

  public let selection: WatchNativeSelection
  public let revision: UInt64
  public let state: State
  /// Present iff `state == .declined`.
  public let declineReason: DeclineReason?
  /// Present iff `state == .ready`; the admitted file's byte count, which counts against the
  /// Watch's shared budget.
  public let committedBytes: Int64?
  /// Present iff `state == .downloading` and the download's own length is known; `nil` until then.
  public let progress: Double?
  /// Present iff `state == .failed`.
  public let failureReason: FailureReason?

  public init(
    selection: WatchNativeSelection, revision: UInt64, state: State, declineReason: DeclineReason? = nil,
    committedBytes: Int64? = nil, progress: Double? = nil, failureReason: FailureReason? = nil
  ) throws {
    self.selection = selection
    self.revision = revision
    self.state = state
    self.declineReason = declineReason
    self.committedBytes = committedBytes
    self.progress = progress
    self.failureReason = failureReason
    try validate()
  }

  /// Tolerant on purpose, as `WatchSetupChallenge` is for health: a state, a failure reason or a
  /// progress value this build does not know must not make the whole report undecodable, which
  /// would turn a working Watch into no answer at all. Fields that do not belong to the decoded
  /// state are dropped for the same reason.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let state =
      (try? container.decode(String.self, forKey: .state)).flatMap(State.init(rawValue:)) ?? .receiving
    let decodedProgress = try? container.decodeIfPresent(Double.self, forKey: .progress)
    let progress = decodedProgress.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
    let decodedFailure = try? container.decodeIfPresent(String.self, forKey: .failureReason)
    try self.init(
      selection: container.decode(WatchNativeSelection.self, forKey: .selection),
      revision: container.decode(UInt64.self, forKey: .revision),
      state: state,
      declineReason: container.decodeIfPresent(DeclineReason.self, forKey: .declineReason),
      committedBytes: container.decodeIfPresent(Int64.self, forKey: .committedBytes),
      progress: state == .downloading ? progress : nil,
      failureReason: state == .failed
        ? (decodedFailure.flatMap(FailureReason.init(rawValue:)) ?? .invalidResponse) : nil)
  }

  public func validate() throws {
    try selection.validate()
    guard revision > 0 else { throw WatchProtocolCodingError.invalidValue }
    switch state {
    case .declined:
      guard declineReason != nil, committedBytes == nil, progress == nil, failureReason == nil else {
        throw WatchProtocolCodingError.invalidValue
      }
    case .ready:
      guard declineReason == nil, let committedBytes,
        committedBytes > 0, committedBytes <= WatchEpisodeSendLimits.maxEpisodeBytes,
        progress == nil, failureReason == nil
      else { throw WatchProtocolCodingError.invalidValue }
    case .downloading:
      guard declineReason == nil, committedBytes == nil, failureReason == nil,
        progress.map({ $0.isFinite && (0...1).contains($0) }) ?? true
      else { throw WatchProtocolCodingError.invalidValue }
    case .failed:
      guard failureReason != nil, declineReason == nil, committedBytes == nil, progress == nil else {
        throw WatchProtocolCodingError.invalidValue
      }
    case .receiving, .waitingForNetwork, .removed:
      guard declineReason == nil, committedBytes == nil, progress == nil, failureReason == nil else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
  }

  private enum CodingKeys: String, CodingKey {
    case selection, revision, state, declineReason, committedBytes, progress, failureReason
  }
}

/// The Watch's authoritative report of what it holds. The phone never marks an episode "On Watch"
/// from an offer alone; only a `ready` entry for the same revision does. Sent by
/// `transferUserInfo` after each change; the phone keeps the highest `sequence`.
public struct WatchEpisodeInventory: WatchWireValue, Equatable {
  public static let transportKey = WatchTransportKey.episodeInventory
  public static let maxWireBytes = WatchEpisodeSendLimits.maxInventoryWireBytes
  public let version: Int
  /// Always present: the phone keys the desired set by this identity.
  public let watchInstallID: String
  public let sequence: UInt64
  /// The newest offer generation the Watch has applied; 0 means it has applied none.
  public let acknowledgedGeneration: UInt64
  /// False while the Watch has no signed-in Audiobookshelf account, so the phone re-offers after
  /// sign-in rather than reading a decline as a full or broken Watch (ADR 0019 decision 5).
  public let acceptsCopies: Bool
  public let entries: [WatchEpisodeInventoryEntry]
  /// The Watch's whole quota, shared by ABS downloads and received copies.
  public let budgetTotalBytes: Int64
  /// Bytes currently used. It may exceed `budgetTotalBytes` only when the Watch was already over
  /// before this inventory, which the phone treats as a full Watch rather than an invalid report.
  public let budgetUsedBytes: Int64
  public let observedAt: Date
  // The three Audiobookshelf fields are optional stored properties, not defaulted ones: the
  // `Codable` is synthesized, and a non-optional field would make this build reject every
  // inventory from an older Watch, RSS half included (ADR 0021 Decision 9).
  /// Every Audiobookshelf group the Watch holds, from either origin; `nil` from a Watch that
  /// predates Audiobookshelf sends.
  public let absEntries: [WatchABSInventoryEntry]?
  /// The newest Audiobookshelf offer generation the Watch has applied, counted apart from
  /// `acknowledgedGeneration`. `nil` or 0 means it has applied none.
  public let absAcknowledgedGeneration: UInt64?
  /// The Watch's account when it wrote `absEntries`. The phone applies them only when this equals
  /// its own authenticated stamp (ADR 0021 Decision 5).
  public let absAccountStamp: WatchAccountStamp?

  public init(
    watchInstallID: String, sequence: UInt64, acknowledgedGeneration: UInt64, acceptsCopies: Bool,
    entries: [WatchEpisodeInventoryEntry], budgetTotalBytes: Int64, budgetUsedBytes: Int64, observedAt: Date,
    absEntries: [WatchABSInventoryEntry]? = nil, absAcknowledgedGeneration: UInt64? = nil,
    absAccountStamp: WatchAccountStamp? = nil
  ) throws {
    self.version = WatchProtocolVersion.current
    self.watchInstallID = watchInstallID
    self.sequence = sequence
    self.acknowledgedGeneration = acknowledgedGeneration
    self.acceptsCopies = acceptsCopies
    self.entries = entries
    self.budgetTotalBytes = budgetTotalBytes
    self.budgetUsedBytes = budgetUsedBytes
    self.observedAt = observedAt
    self.absEntries = absEntries
    self.absAcknowledgedGeneration = absAcknowledgedGeneration
    self.absAccountStamp = absAccountStamp
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    try WatchInstallIdentity.validate(watchInstallID)
    let absEntries = absEntries ?? []
    guard entries.count + absEntries.count <= WatchEpisodeSendLimits.maxInventoryEntries else {
      throw WatchProtocolCodingError.tooManyRows
    }
    guard Set(entries.map(\.selection)).count == entries.count,
      Set(absEntries.map(\.selection)).count == absEntries.count
    else { throw WatchProtocolCodingError.invalidValue }
    for entry in entries { try entry.validate() }
    for entry in absEntries { try entry.validate() }
    try absAccountStamp?.validate()
    guard budgetTotalBytes >= 0, budgetUsedBytes >= 0 else { throw WatchProtocolCodingError.invalidValue }
    try WatchEpisodeSendValidation.date(observedAt)
  }
}
