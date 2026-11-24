import Foundation
import Testing

@testable import WatchProtocol

/// The phone's desired set of Audiobookshelf books and episodes, and the Watch's report of the
/// Audiobookshelf groups it holds (ADR 0021 Decisions 1, 3, 4 and 9).
struct WatchABSSendTests {
  private let sentAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let installID = "a1b2c3d4-0000-4000-8000-000000000001"

  // MARK: Offer

  @Test func offerRoundTripsThroughTheWireCodec() throws {
    let offer = try offer(entries: [entry(0), entry(1, episodeID: nil)], removals: [selection(2)])
    let decoded = try WatchProtocolFixtures.roundTrip(offer)
    #expect(decoded == offer)
    #expect(decoded.accountStamp == WatchProtocolFixtures.accountStamp())
    #expect(decoded.removals == [try selection(2)])
    #expect(WatchABSSendOffer.transportKey == "whirr.watch.abs.offer.v1")
    #expect(WatchABSSendOffer.maxWireBytes == 64 * 1024)
  }

  @Test func decodeRejectsAnotherProtocolVersion() throws {
    var object = try encodedObject(try offer())
    object["version"] = WatchProtocolVersion.current + 1
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(WatchProtocolVersion.current + 1)) {
      try WatchWireCodec.decode(WatchABSSendOffer.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  @Test func offerRejectsAMissingGenerationOrForeignInstall() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try offer(generation: 0) }
    for bad in ["not-a-uuid", "", installID.uppercased()] {
      #expect(throws: WatchProtocolCodingError.invalidValue) { try offer(installID: bad) }
    }
    #expect(try offer(installID: nil).watchInstallID == nil)
  }

  /// Entries and removals share one row cap, so an offer can never name more than 100 selections.
  @Test func entriesAndRemovalsCountTogetherAgainstTheRowCap() throws {
    let cap = WatchABSSendLimits.maxOfferRows
    #expect(cap == WatchProtocolVersion.maxRows)
    let entries = try (0..<60).map { try entry($0) }
    let fits = try (60..<cap).map { try selection($0) }
    #expect(try offer(entries: entries, removals: fits).removals.count == cap - 60)
    let over = try (60...cap).map { try selection($0) }
    #expect(throws: WatchProtocolCodingError.tooManyRows) { try offer(entries: entries, removals: over) }
  }

  @Test func offerRejectsASelectionInBothLists() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try offer(entries: [entry(0)], removals: [selection(0)])
    }
  }

  @Test func offerRejectsADuplicateWithinEitherList() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try offer(entries: [entry(0), entry(0)]) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try offer(removals: [selection(0), selection(0)])
    }
    // A book and one of its episodes are different selections.
    #expect(try offer(entries: [entry(0), entry(0, episodeID: nil)]).entries.count == 2)
  }

  @Test func offerValidatesItsAccountStamp() throws {
    var object = try encodedObject(try offer())
    var stamp = try #require(object["accountStamp"] as? [String: Any])
    stamp["accountIdentityHash"] = ""
    object["accountStamp"] = stamp
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(WatchABSSendOffer.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  /// `WatchABSSelection` throws `WatchHandoffError` on its own; on this key the Watch's ingress
  /// handles one error type, so the offer maps it.
  @Test func anInvalidSelectionSurfacesAsAProtocolCodingError() throws {
    for list in ["entries", "removals"] {
      var object = try encodedObject(try offer(entries: [entry(0)], removals: [selection(1)]))
      var rows = try #require(object[list] as? [[String: Any]])
      if list == "entries" {
        var row = try #require(rows[0]["selection"] as? [String: Any])
        row["itemID"] = "file:///etc/passwd"
        rows[0]["selection"] = row
      } else {
        rows[0]["itemID"] = ""
      }
      object[list] = rows
      #expect(throws: WatchProtocolCodingError.invalidSelection, "\(list)") {
        try WatchWireCodec.decode(WatchABSSendOffer.self, from: JSONSerialization.data(withJSONObject: object))
      }
    }
  }

  @Test func entryRejectsAZeroRevisionAndImpossibleValues() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, revision: 0) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, declaredBytes: 0) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, declaredBytes: WatchABSSendLimits.maxItemBytes + 1)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, position: -1) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, position: .nan) }
    // A book larger than one RSS episode's cap is ordinary; the Watch's budget, not the wire,
    // decides whether it fits.
    let book = WatchEpisodeSendLimits.maxEpisodeBytes * 3
    #expect(try entry(0, declaredBytes: book).declaredBytes == book)
    #expect(try entry(0, declaredBytes: nil, position: nil).position == nil)
  }

  /// The offer carries titles for display only, never a URL, token or path (ADR 0021 Decision 1).
  @Test func entryMetadataRefusesURLsAndPaths() throws {
    #expect(throws: WatchProtocolCodingError.forbiddenMetadata) {
      try entry(0, title: "https://abs.example.test/api/items/book?token=secret")
    }
    #expect(throws: WatchProtocolCodingError.forbiddenMetadata) { try entry(0, subtitle: "/var/mobile/book") }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, title: "") }
    #expect(throws: WatchProtocolCodingError.oversizedMetadata) {
      try entry(0, title: String(repeating: "t", count: WatchProtocolVersion.maxMetadataStringBytes + 1))
    }
    // A book with no author has no subtitle.
    #expect(try entry(0, subtitle: nil).subtitle == nil)
  }

  @Test func anOlderPhonesEntryWithoutOptionalFieldsDecodes() throws {
    var object = try encodedObject(try offer(entries: [entry(0)]))
    var rows = try #require(object["entries"] as? [[String: Any]])
    for key in ["subtitle", "declaredBytes", "position"] { rows[0].removeValue(forKey: key) }
    object["entries"] = rows
    let decoded = try WatchWireCodec.decode(
      WatchABSSendOffer.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.entries.first?.subtitle == nil)
    #expect(decoded.entries.first?.declaredBytes == nil)
    #expect(decoded.entries.first?.position == nil)
  }

  /// The phone names the matching inventory it last applied, so the Watch can tell an offer built
  /// from re-adopted rows from one built by a phone that has lost them.
  @Test func theInventorySequenceTravelsAndIsOptional() throws {
    let stamped = try WatchABSSendOffer(
      generation: 4, watchInstallID: installID, accountStamp: WatchProtocolFixtures.accountStamp(),
      entries: [entry(0)], removals: [], sentAt: sentAt, inventorySequence: 9)
    #expect(try WatchProtocolFixtures.roundTrip(stamped).inventorySequence == 9)
    #expect(try offer().inventorySequence == nil)

    var object = try encodedObject(stamped)
    object.removeValue(forKey: "inventorySequence")
    let older = try WatchWireCodec.decode(
      WatchABSSendOffer.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(older.inventorySequence == nil)

    let fitted = try WatchABSSendOffer.fitting(
      generation: 4, watchInstallID: installID, accountStamp: WatchProtocolFixtures.accountStamp(),
      entries: [entry(0)], removals: [], sentAt: sentAt, inventorySequence: 9)
    #expect(fitted.offer.inventorySequence == 9)
  }

  // MARK: Fitting

  @Test func fittingKeepsTheLongestPrefixAndReportsWhatWasOmitted() throws {
    let long = WatchProtocolVersion.maxMetadataStringBytes
    let entries = try (0..<WatchABSSendLimits.maxOfferRows).map {
      try entry(
        $0, title: String(repeating: "t", count: long), subtitle: String(repeating: "s", count: long))
    }
    let result = try fit(entries: entries)
    #expect(!result.omitted.isEmpty)
    #expect(result.omittedRemovals.isEmpty)
    #expect(result.offer.entries.count + result.omitted.count == entries.count)
    #expect(result.offer.entries == Array(entries.prefix(result.offer.entries.count)))
    #expect(result.omitted == entries.dropFirst(result.offer.entries.count).map(\.selection))
    #expect(try WatchWireCodec.encode(result.offer).count <= WatchABSSendOffer.maxWireBytes)
  }

  @Test func fittingKeepsEveryShortEntryAndRemoval() throws {
    let entries = try (0..<50).map { try entry($0) }
    let removals = try (50..<WatchABSSendLimits.maxOfferRows).map { try selection($0) }
    let result = try fit(entries: entries, removals: removals)
    #expect(result.omitted.isEmpty)
    #expect(result.omittedRemovals.isEmpty)
    #expect(try WatchProtocolFixtures.roundTrip(result.offer) == result.offer)
  }

  /// Removals free space on the Watch, so they are kept ahead of any entry. Removals that still do
  /// not fit are returned, so the phone keeps them pending for the next offer.
  @Test func fittingKeepsRemovalsBeforeEntries() throws {
    let long = WatchProtocolVersion.maxMetadataStringBytes
    let removals = try (0..<WatchABSSendLimits.maxOfferRows).map { index in
      let prefix = "\(index)-"
      return try WatchABSSelection(
        itemID: prefix + String(repeating: "i", count: long - prefix.utf8.count),
        episodeID: String(repeating: "e", count: long))
    }
    let result = try fit(entries: [], removals: removals)
    #expect(!result.omittedRemovals.isEmpty)
    #expect(result.offer.removals == Array(removals.prefix(result.offer.removals.count)))
    #expect(result.omittedRemovals == Array(removals.dropFirst(result.offer.removals.count)))
    #expect(try WatchWireCodec.encode(result.offer).count <= WatchABSSendOffer.maxWireBytes)

    let longEntry = try entry(
      500, title: String(repeating: "t", count: long), subtitle: String(repeating: "s", count: long))
    let crowded = try fit(entries: [longEntry], removals: Array(removals.prefix(result.offer.removals.count)))
    #expect(crowded.offer.removals.count == result.offer.removals.count)
    #expect(crowded.omitted == [try selection(500)])
  }

  /// A duplicate is a caller bug, so `fitting` surfaces it instead of treating it as "did not fit".
  @Test func fittingRefusesAnInvalidSetRatherThanTrimmingIt() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try fit(entries: [entry(0), entry(0)]) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try fit(entries: [entry(0)], removals: [selection(0)])
    }
  }

  // MARK: Inventory entry

  @Test func inventoryEntriesRoundTripInEveryState() throws {
    let entries = try [
      inventoryEntry(0, state: .ready, committedBytes: WatchEpisodeSendLimits.maxEpisodeBytes * 2, tracks: (12, 12)),
      inventoryEntry(1, origin: .watch, state: .ready, committedBytes: 40_000_000, tracks: (1, 1)),
      inventoryEntry(2, state: .receiving, tracks: (12, 3)),
      inventoryEntry(3, state: .downloading, progress: 0.42, tracks: (12, 5)),
      inventoryEntry(4, origin: .watch, state: .waitingForNetwork, tracks: (2, 0)),
      inventoryEntry(5, state: .failed, failureReason: .itemMissing, tracks: (0, 0)),
      inventoryEntry(6, state: .declined, declineReason: .storageFull, tracks: (0, 0)),
      inventoryEntry(7, state: .removed, tracks: (0, 0)),
    ]
    let inventory = try inventory(absEntries: entries)
    let decoded = try WatchProtocolFixtures.roundTrip(inventory)
    #expect(decoded == inventory)
    #expect(decoded.absEntries?.map(\.origin) == [.phone, .watch, .phone, .phone, .watch, .phone, .phone, .phone])
  }

  @Test func theOriginsAndPreEnqueueFailuresUseTheAgreedRawValues() {
    #expect(WatchABSOrigin.phone.rawValue == "phone")
    #expect(WatchABSOrigin.watch.rawValue == "watch")
    #expect(WatchEpisodeInventoryEntry.FailureReason.itemMissing.rawValue == "item_missing")
    #expect(WatchEpisodeInventoryEntry.FailureReason.noAudio.rawValue == "no_audio")
    #expect(WatchEpisodeInventoryEntry.FailureReason.planInvalid.rawValue == "plan_invalid")
  }

  /// A phone-origin group answers a revision the phone sent; a Watch-origin group has none.
  @Test func onlyAPhoneOriginEntryCarriesARevision() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, origin: .phone, revision: .some(nil), state: .receiving, tracks: (1, 0))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, origin: .phone, revision: 0, state: .receiving, tracks: (1, 0))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, origin: .watch, revision: 3, state: .receiving, tracks: (1, 0))
    }
  }

  @Test func readyNeedsBytesAndEveryTrack() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try inventoryEntry(0, state: .ready, tracks: (2, 2)) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .ready, committedBytes: 1_000, tracks: (2, 1))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .ready, committedBytes: 1_000, tracks: (0, 0))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .ready, committedBytes: WatchABSSendLimits.maxItemBytes + 1, tracks: (1, 1))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .receiving, committedBytes: 1_000, tracks: (1, 0))
    }
  }

  @Test func trackCountsAreBounded() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .downloading, tracks: (2, 3))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .downloading, tracks: (-1, 0))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .downloading, tracks: (WatchABSSendLimits.maxTrackCount + 1, 0))
    }
  }

  /// The RSS entry's state rules apply unchanged: each reason belongs to exactly one state.
  @Test func reasonsAndProgressBelongToTheirStates() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try inventoryEntry(0, state: .declined, tracks: (0, 0)) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try inventoryEntry(0, state: .failed, tracks: (0, 0)) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .receiving, failureReason: .noAudio, tracks: (0, 0))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .receiving, progress: 0.5, tracks: (1, 0))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try inventoryEntry(0, state: .downloading, progress: 1.5, tracks: (1, 0))
    }
  }

  // MARK: Tolerant decoding

  /// An origin this build does not know reads as the Watch's own: the phone never removes a
  /// Watch-origin group by omission, so that is the reading that cannot delete anything.
  @Test func anUnknownOriginDecodesAsWatchAndDropsItsRevision() throws {
    let decoded = try decodeRewritten(inventoryEntry(0, state: .receiving, tracks: (1, 0))) {
      $0["origin"] = "tablet"
    }
    #expect(decoded.origin == .watch)
    #expect(decoded.revision == nil)
  }

  @Test func unknownStatesAndReasonsFallBackAsTheRSSEntryDoes() throws {
    let state = try decodeRewritten(inventoryEntry(0, state: .receiving, tracks: (1, 0))) {
      $0["state"] = "quantum"
    }
    #expect(state.state == .receiving)
    let reason = try decodeRewritten(inventoryEntry(0, state: .failed, failureReason: .noAudio, tracks: (0, 0))) {
      $0["failureReason"] = "cosmic_rays"
    }
    #expect(reason.failureReason == .invalidResponse)
    let progress = try decodeRewritten(inventoryEntry(0, state: .downloading, progress: 0.5, tracks: (1, 0))) {
      $0["progress"] = 7
    }
    #expect(progress.progress == nil)
  }

  @Test func missingTrackCountsDecodeAsNone() throws {
    let decoded = try decodeRewritten(inventoryEntry(0, state: .receiving, tracks: (4, 1))) {
      $0.removeValue(forKey: "trackCount")
      $0.removeValue(forKey: "completedTracks")
    }
    #expect(decoded.trackCount == 0)
    #expect(decoded.completedTracks == 0)
  }

  // MARK: Helpers

  private func selection(_ index: Int, episodeID: String? = "episode") throws -> WatchABSSelection {
    try WatchABSSelection(itemID: "item-\(index)", episodeID: episodeID.map { "\($0)-\(index)" })
  }

  private func entry(
    _ index: Int, episodeID: String? = "episode", revision: UInt64 = 1, title: String = "Title",
    subtitle: String? = "Author", declaredBytes: Int64? = 50_000_000, position: Double? = 12
  ) throws -> WatchABSOfferEntry {
    try WatchABSOfferEntry(
      selection: selection(index, episodeID: episodeID), revision: revision, title: title, subtitle: subtitle,
      declaredBytes: declaredBytes, position: position)
  }

  private func offer(
    generation: UInt64 = 2, installID: String? = "a1b2c3d4-0000-4000-8000-000000000001",
    entries: [WatchABSOfferEntry] = [], removals: [WatchABSSelection] = []
  ) throws -> WatchABSSendOffer {
    try WatchABSSendOffer(
      generation: generation, watchInstallID: installID, accountStamp: WatchProtocolFixtures.accountStamp(),
      entries: entries, removals: removals, sentAt: sentAt)
  }

  private func fit(
    entries: [WatchABSOfferEntry], removals: [WatchABSSelection] = []
  ) throws -> (offer: WatchABSSendOffer, omitted: [WatchABSSelection], omittedRemovals: [WatchABSSelection]) {
    try WatchABSSendOffer.fitting(
      generation: 3, watchInstallID: installID, accountStamp: WatchProtocolFixtures.accountStamp(),
      entries: entries, removals: removals, sentAt: sentAt)
  }

  private func inventoryEntry(
    _ index: Int, origin: WatchABSOrigin = .phone, revision: UInt64?? = .none,
    state: WatchEpisodeInventoryEntry.State, declineReason: WatchEpisodeInventoryEntry.DeclineReason? = nil,
    committedBytes: Int64? = nil, progress: Double? = nil,
    failureReason: WatchEpisodeInventoryEntry.FailureReason? = nil, tracks: (Int, Int)
  ) throws -> WatchABSInventoryEntry {
    let revision: UInt64? = revision ?? (origin == .phone ? 1 : nil)
    return try WatchABSInventoryEntry(
      selection: selection(index), revision: revision, origin: origin, state: state, trackCount: tracks.0,
      completedTracks: tracks.1, declineReason: declineReason, failureReason: failureReason, progress: progress,
      committedBytes: committedBytes)
  }

  private func inventory(absEntries: [WatchABSInventoryEntry]) throws -> WatchEpisodeInventory {
    try WatchEpisodeInventory(
      watchInstallID: installID, sequence: 7, acknowledgedGeneration: 3, acceptsCopies: true, entries: [],
      budgetTotalBytes: 2_000_000_000, budgetUsedBytes: 0, observedAt: sentAt, absEntries: absEntries,
      absAcknowledgedGeneration: 4, absAccountStamp: WatchProtocolFixtures.accountStamp())
  }

  private func encodedObject<Value: WatchWireValue>(_ value: Value) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(value)) as? [String: Any])
  }

  /// Rewrites the only ABS entry of an encoded inventory, as a newer Watch might write it.
  private func decodeRewritten(
    _ entry: WatchABSInventoryEntry, _ change: (inout [String: Any]) -> Void
  ) throws -> WatchABSInventoryEntry {
    var object = try encodedObject(try inventory(absEntries: [entry]))
    var rows = try #require(object["absEntries"] as? [[String: Any]])
    change(&rows[0])
    object["absEntries"] = rows
    let decoded = try WatchWireCodec.decode(
      WatchEpisodeInventory.self, from: JSONSerialization.data(withJSONObject: object))
    return try #require(decoded.absEntries?.first)
  }
}
