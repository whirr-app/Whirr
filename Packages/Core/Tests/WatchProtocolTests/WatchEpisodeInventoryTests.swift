import Foundation
import Testing

@testable import WatchProtocol

/// The Watch's authoritative report of the native-RSS copies it holds.
struct WatchEpisodeInventoryTests {
  private let observedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let installID = "a1b2c3d4-0000-4000-8000-000000000001"

  @Test func inventoryRoundTripsThroughTheWireCodec() throws {
    let inventory = try inventory(entries: [
      try entry(0, state: .ready, committedBytes: 40_000_000),
      try entry(1, state: .receiving),
      try entry(2, state: .declined, declineReason: .storageFull),
      try entry(3, state: .removed),
      try entry(4, state: .downloading, progress: 0.42),
      try entry(5, state: .waitingForNetwork),
      try entry(6, state: .failed, failureReason: .tooLarge),
    ])
    let decoded = try WatchProtocolFixtures.roundTrip(inventory)
    #expect(decoded == inventory)
    #expect(
      decoded.entries.map(\.state)
        == [.ready, .receiving, .declined, .removed, .downloading, .waitingForNetwork, .failed])
    #expect(WatchEpisodeInventory.transportKey == "whirr.watch.episode.inventory.v1")
  }

  @Test func theNewStatesUseTheAgreedRawValues() {
    #expect(WatchEpisodeInventoryEntry.State.downloading.rawValue == "downloading")
    #expect(WatchEpisodeInventoryEntry.State.waitingForNetwork.rawValue == "waiting_for_network")
    #expect(WatchEpisodeInventoryEntry.State.failed.rawValue == "failed")
    #expect(WatchEpisodeInventoryEntry.FailureReason.httpStatus.rawValue == "http_status")
    #expect(WatchEpisodeInventoryEntry.FailureReason.insecureRedirect.rawValue == "insecure_redirect")
    #expect(WatchEpisodeInventoryEntry.FailureReason.tooLarge.rawValue == "too_large")
    #expect(WatchEpisodeInventoryEntry.FailureReason.invalidResponse.rawValue == "invalid_response")
    #expect(WatchEpisodeInventoryEntry.FailureReason.network.rawValue == "network")
  }

  @Test func decodeRejectsAnotherProtocolVersion() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(try inventory())) as? [String: Any])
    object["version"] = WatchProtocolVersion.current + 1
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(WatchProtocolVersion.current + 1)) {
      try WatchWireCodec.decode(WatchEpisodeInventory.self, from: data)
    }
  }

  @Test func inventoryRequiresACanonicalInstallIdentity() throws {
    for bad in ["", "not-a-uuid", installID.uppercased()] {
      #expect(throws: WatchProtocolCodingError.invalidValue) { try inventory(installID: bad) }
    }
  }

  @Test func inventoryRejectsMoreEntriesThanTheRowCap() throws {
    let entries = try (0...WatchEpisodeSendLimits.maxInventoryEntries).map { try entry($0, state: .receiving) }
    #expect(throws: WatchProtocolCodingError.tooManyRows) { try inventory(entries: entries) }
  }

  @Test func inventoryRejectsTwoEntriesForOneEpisode() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventory(entries: [try entry(0, state: .receiving), try entry(0, state: .ready, committedBytes: 1)])
    }
  }

  @Test func inventoryRejectsNegativeBudgets() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventory(budgetTotalBytes: -1)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventory(budgetUsedBytes: -1)
    }
    // Already over budget is a real state the phone reads as full, not a malformed report.
    #expect(try inventory(budgetTotalBytes: 100, budgetUsedBytes: 200).budgetUsedBytes == 200)
  }

  @Test func inventoryRejectsAZeroRevision() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, revision: 0, state: .receiving)
    }
  }

  @Test func aDeclineNeedsAReasonAndAReasonNeedsADecline() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, state: .declined) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .ready, declineReason: .storageFull, committedBytes: 1_000)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, state: .receiving, declineReason: .invalid) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, state: .removed, declineReason: .signedOut) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .declined, declineReason: .storageFull, progress: 0.5)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .declined, declineReason: .storageFull, failureReason: .network)
    }
  }

  @Test func readyNeedsCommittedBytesWithinTheEpisodeCap() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, state: .ready) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, state: .ready, committedBytes: 0) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .ready, committedBytes: WatchEpisodeSendLimits.maxEpisodeBytes + 1)
    }
    // Non-ready states never carry bytes.
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .receiving, committedBytes: 1_000)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .removed, committedBytes: 1_000)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .declined, declineReason: .storageFull, committedBytes: 1_000)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .downloading, committedBytes: 1_000)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .failed, committedBytes: 1_000, failureReason: .network)
    }
    // A ready entry carries no progress and no failure.
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .ready, committedBytes: 1_000, progress: 0.5)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .ready, committedBytes: 1_000, failureReason: .network)
    }
  }

  @Test func downloadingProgressIsAFractionOrUnknown() throws {
    #expect(try entry(0, state: .downloading).progress == nil)
    #expect(try entry(0, state: .downloading, progress: 0).progress == 0)
    #expect(try entry(0, state: .downloading, progress: 1).progress == 1)
    #expect(try entry(0, state: .downloading, progress: 0.42).progress == 0.42)
    for bad in [-0.01, 1.01, Double.nan, Double.infinity] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try entry(0, state: .downloading, progress: bad)
      }
    }
  }

  @Test func onlyAFailureCarriesAReason() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, state: .failed) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .failed, progress: 0.5, failureReason: .network)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .receiving, failureReason: .network)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, state: .waitingForNetwork, failureReason: .network)
    }
    #expect(
      try entry(0, state: .failed, failureReason: .httpStatus).failureReason == .httpStatus)
    #expect(try entry(0, state: .downloading, progress: 0.5).progress == 0.5)
  }

  // MARK: Tolerant decoding

  /// A newer Watch's vocabulary must not make its whole report undecodable (ADR 0020 Decision 7):
  /// unknown values fall back to the closest state this build understands.
  @Test func unknownStateDecodesAsQueued() throws {
    let data = try rewriteEntry(
      WatchWireCodec.encode(try inventory(entries: [try entry(0, state: .receiving)]))
    ) { $0["state"] = "quantum" }
    let decoded = try WatchWireCodec.decode(WatchEpisodeInventory.self, from: data)
    #expect(decoded.entries.first?.state == .receiving)
  }

  @Test func unknownFailureReasonDecodesAsAnInvalidResponse() throws {
    let data = try rewriteEntry(
      WatchWireCodec.encode(
        try inventory(entries: [try entry(0, state: .failed, failureReason: .network)]))
    ) { $0["failureReason"] = "cosmic_rays" }
    let decoded = try WatchWireCodec.decode(WatchEpisodeInventory.self, from: data)
    #expect(decoded.entries.first?.failureReason == .invalidResponse)
  }

  @Test func aFailureWithoutItsReasonDecodesAsAnInvalidResponse() throws {
    let data = try rewriteEntry(
      WatchWireCodec.encode(
        try inventory(entries: [try entry(0, state: .failed, failureReason: .network)]))
    ) { $0.removeValue(forKey: "failureReason") }
    let decoded = try WatchWireCodec.decode(WatchEpisodeInventory.self, from: data)
    #expect(decoded.entries.first?.failureReason == .invalidResponse)
  }

  @Test func unknownOrOutOfRangeProgressDecodesAsUnknown() throws {
    for replacement in [1.5, -0.5, "half", Int64.max] as [Any] {
      let data = try rewriteEntry(
        WatchWireCodec.encode(try inventory(entries: [try entry(0, state: .downloading, progress: 0.5)]))
      ) { $0["progress"] = replacement }
      let decoded = try WatchWireCodec.decode(WatchEpisodeInventory.self, from: data)
      #expect(decoded.entries.first?.progress == nil, "\(replacement) should decode as unknown")
    }
  }

  @Test func aKnownProgressSurvivesDecoding() throws {
    let data = try rewriteEntry(
      WatchWireCodec.encode(try inventory(entries: [try entry(0, state: .downloading, progress: 0.5)]))
    ) { $0["progress"] = 0.75 }
    let decoded = try WatchWireCodec.decode(WatchEpisodeInventory.self, from: data)
    #expect(decoded.entries.first?.progress == 0.75)
  }

  @Test func anOversizedInventoryIsRejectedByTheCodec() throws {
    // The longest identifiers the wire accepts, so the inventory stays oversized whatever the cap,
    // up to the point the precondition below names.
    let limit = WatchProtocolVersion.maxMetadataStringBytes
    try #require(WatchProtocolVersion.maxRows * 2 * limit > WatchEpisodeInventory.maxWireBytes)
    let feedID = String(repeating: "f", count: limit)
    let entries = try (0..<WatchProtocolVersion.maxRows).map { index in
      let prefix = "\(index)-"
      let episodeID = prefix + String(repeating: "e", count: limit - prefix.utf8.count)
      return try WatchEpisodeInventoryEntry(
        selection: WatchNativeSelection(feedID: feedID, episodeID: episodeID),
        revision: 1, state: .receiving)
    }
    let inventory = try inventory(entries: entries)
    #expect(throws: WatchProtocolCodingError.tooLarge) { try WatchWireCodec.encode(inventory) }
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(
        WatchEpisodeInventory.self, from: Data(repeating: 0x20, count: WatchEpisodeInventory.maxWireBytes + 1))
    }
  }

  // MARK: Audiobookshelf half (ADR 0021 Decision 9)

  /// The inventory's `Codable` is synthesized, so a new required key would make this phone reject
  /// every inventory from an older Watch and lose its RSS half with it.
  @Test func anOlderWatchsInventoryWithNoABSKeysDecodesAndKeepsItsRSSHalf() throws {
    let older = try inventory(entries: [try entry(0, state: .ready, committedBytes: 1_000)])
    let object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(older)) as? [String: Any])
    for key in ["absEntries", "absAcknowledgedGeneration", "absAccountStamp"] {
      #expect(object[key] == nil, "\(key) must be absent from an RSS-only inventory")
    }
    let decoded = try WatchWireCodec.decode(
      WatchEpisodeInventory.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.entries == older.entries)
    #expect(decoded.acknowledgedGeneration == 3)
    #expect(decoded.absEntries == nil)
    #expect(decoded.absAcknowledgedGeneration == nil)
    #expect(decoded.absAccountStamp == nil)
  }

  /// A phone on the current build decodes the inventory with the shape it knows, and ignores the
  /// Audiobookshelf keys.
  @Test func anInventoryWithABSEntriesDecodesOnABuildThatKnowsOnlyRSS() throws {
    let current = try inventory(
      entries: [try entry(0, state: .ready, committedBytes: 1_000)], absEntries: [try absEntry(0)],
      absAcknowledgedGeneration: 9, absAccountStamp: WatchProtocolFixtures.accountStamp())
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let older = try decoder.decode(RSSOnlyInventory.self, from: WatchWireCodec.encode(current))
    #expect(older.entries == current.entries)
    #expect(older.acknowledgedGeneration == current.acknowledgedGeneration)
    #expect(older.watchInstallID == current.watchInstallID)
  }

  @Test func theABSHalfRoundTrips() throws {
    let inventory = try inventory(
      absEntries: [try absEntry(0), try absEntry(1)], absAcknowledgedGeneration: 9,
      absAccountStamp: WatchProtocolFixtures.accountStamp())
    let decoded = try WatchProtocolFixtures.roundTrip(inventory)
    #expect(decoded == inventory)
    #expect(decoded.absAcknowledgedGeneration == 9)
    #expect(decoded.absAccountStamp == WatchProtocolFixtures.accountStamp())
  }

  @Test func rssAndABSEntriesShareOneRowCap() throws {
    let rss = try (0..<60).map { try entry($0, state: .receiving) }
    let fits = try (0..<(WatchEpisodeSendLimits.maxInventoryEntries - 60)).map { try absEntry($0) }
    #expect(try inventory(entries: rss, absEntries: fits).absEntries?.count == fits.count)
    let over = try (0...(WatchEpisodeSendLimits.maxInventoryEntries - 60)).map { try absEntry($0) }
    #expect(throws: WatchProtocolCodingError.tooManyRows) { try inventory(entries: rss, absEntries: over) }
  }

  @Test func inventoryRejectsTwoABSEntriesForOneSelection() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventory(absEntries: [try absEntry(0), try absEntry(0)])
    }
  }

  @Test func inventoryValidatesItsABSAccountStamp() throws {
    let encoded = try WatchWireCodec.encode(
      try inventory(absEntries: [], absAccountStamp: WatchProtocolFixtures.accountStamp()))
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["absAccountStamp"] = ["accountIdentityHash": "", "serverIdentityHash": "server-hash"]
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(WatchEpisodeInventory.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  // MARK: Helpers

  private func selection(_ index: Int = 0) throws -> WatchNativeSelection {
    try WatchNativeSelection(feedID: "feed-\(index)", episodeID: "episode-\(index)")
  }

  private func entry(
    _ index: Int = 0, revision: UInt64 = 1, state: WatchEpisodeInventoryEntry.State,
    declineReason: WatchEpisodeInventoryEntry.DeclineReason? = nil, committedBytes: Int64? = nil,
    progress: Double? = nil, failureReason: WatchEpisodeInventoryEntry.FailureReason? = nil
  ) throws -> WatchEpisodeInventoryEntry {
    try WatchEpisodeInventoryEntry(
      selection: selection(index), revision: revision, state: state, declineReason: declineReason,
      committedBytes: committedBytes, progress: progress, failureReason: failureReason)
  }

  /// Rewrites the first entry of an encoded inventory, so a test can put an unknown or malformed
  /// value where a newer Watch might put one.
  private func rewriteEntry(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var entries = try #require(object["entries"] as? [[String: Any]])
    change(&entries[0])
    object["entries"] = entries
    return try JSONSerialization.data(withJSONObject: object)
  }

  private func inventory(
    installID: String = "a1b2c3d4-0000-4000-8000-000000000001",
    entries: [WatchEpisodeInventoryEntry] = [],
    budgetTotalBytes: Int64 = 2 * 1024 * 1024 * 1024,
    budgetUsedBytes: Int64 = 0,
    absEntries: [WatchABSInventoryEntry]? = nil,
    absAcknowledgedGeneration: UInt64? = nil,
    absAccountStamp: WatchAccountStamp? = nil
  ) throws -> WatchEpisodeInventory {
    try WatchEpisodeInventory(
      watchInstallID: installID, sequence: 7, acknowledgedGeneration: 3,
      acceptsCopies: true, entries: entries, budgetTotalBytes: budgetTotalBytes,
      budgetUsedBytes: budgetUsedBytes, observedAt: observedAt, absEntries: absEntries,
      absAcknowledgedGeneration: absAcknowledgedGeneration, absAccountStamp: absAccountStamp)
  }

  private func absEntry(_ index: Int) throws -> WatchABSInventoryEntry {
    try WatchABSInventoryEntry(
      selection: WatchABSSelection(itemID: "item-\(index)", episodeID: nil), revision: 1, origin: .phone,
      state: .receiving, trackCount: 1, completedTracks: 0)
  }

  /// The inventory as a build before ADR 0021 declares it.
  private struct RSSOnlyInventory: Decodable {
    let version: Int
    let watchInstallID: String
    let sequence: UInt64
    let acknowledgedGeneration: UInt64
    let acceptsCopies: Bool
    let entries: [WatchEpisodeInventoryEntry]
    let budgetTotalBytes: Int64
    let budgetUsedBytes: Int64
    let observedAt: Date
  }
}
