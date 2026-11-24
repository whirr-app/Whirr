import Foundation
import Testing

@testable import WatchProtocol

/// The phone's desired set of native-RSS episodes and the prefix rule that keeps an offer inside
/// its byte cap (ADR 0020 Decision 1).
struct WatchEpisodeSendTests {
  private let sentAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
  private let installID = "a1b2c3d4-0000-4000-8000-000000000001"

  @Test func offerRoundTripsThroughTheWireCodec() throws {
    let offer = try offer(entries: [entry(0), entry(1)])
    let decoded = try WatchProtocolFixtures.roundTrip(offer)
    #expect(decoded == offer)
    #expect(decoded.entries.map(\.revision) == [1, 1])
    #expect(WatchEpisodeSendOffer.transportKey == "whirr.watch.episode.offer.v1")
  }

  @Test func decodeRejectsAnotherProtocolVersion() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(try offer())) as? [String: Any])
    object["version"] = WatchProtocolVersion.current + 1
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(WatchProtocolVersion.current + 1)) {
      try WatchWireCodec.decode(WatchEpisodeSendOffer.self, from: data)
    }
  }

  @Test func offerRejectsMoreEntriesThanTheRowCap() throws {
    let entries = try (0...WatchEpisodeSendLimits.maxOfferEntries).map { try entry($0) }
    #expect(throws: WatchProtocolCodingError.tooManyRows) { try offer(entries: entries) }
  }

  @Test func offerRejectsTwoEntriesForOneEpisode() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try offer(entries: [entry(0), entry(0)]) }
  }

  @Test func offerRejectsAMissingOrForeignGenerationAndInstall() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try offer(generation: 0) }
    for bad in ["not-a-uuid", "", installID.uppercased()] {
      #expect(throws: WatchProtocolCodingError.invalidValue) { try offer(installID: bad) }
    }
    // `nil` is valid before the phone has seen an inventory.
    #expect(try offer(installID: nil).watchInstallID == nil)
  }

  @Test func entryRejectsAZeroRevisionAndImpossibleSizes() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, revision: 0) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, declaredBytes: 0) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, declaredBytes: -1) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, declaredBytes: WatchEpisodeSendLimits.maxEpisodeBytes + 1)
    }
    #expect(
      try entry(0, declaredBytes: WatchEpisodeSendLimits.maxEpisodeBytes).declaredBytes
        == WatchEpisodeSendLimits.maxEpisodeBytes)
    // A feed that declared no length is a complete entry; the Watch reserves the cap for it.
    #expect(try entry(0, declaredBytes: nil).declaredBytes == nil)
  }

  @Test func entryRejectsBadTextAndPositions() throws {
    for mime in ["", "audio/mpeg\n", String(repeating: "x", count: WatchEpisodeSendLimits.maxMimeTypeBytes + 1)] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try WatchEpisodeOfferEntry(
          selection: selection(0), revision: 1, title: "Episode", showTitle: "Show", duration: 60,
          declaredBytes: 1_000, enclosureURL: audioURL(0), mimeType: mime, position: 0, lastListenedAt: nil)
      }
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, title: "") }
    #expect(throws: WatchProtocolCodingError.oversizedMetadata) {
      try entry(0, title: String(repeating: "t", count: WatchProtocolVersion.maxMetadataStringBytes + 1))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, position: -.infinity) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, position: -1) }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(0, position: WatchHandoffLimits.maxPositionSeconds + 1)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, duration: 0) }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try entry(0, duration: .nan) }
  }

  @Test func entryRejectsUnsortedOrTooManyChapters() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try entry(
        0,
        chapters: [
          try WatchEpisodeChapter(title: "Second", start: 60),
          try WatchEpisodeChapter(title: "First", start: 0),
        ])
    }
    let many = try (0...WatchEpisodeSendLimits.maxChapters).map {
      try WatchEpisodeChapter(title: "Chapter \($0)", start: Double($0))
    }
    #expect(throws: WatchProtocolCodingError.tooManyRows) { try entry(0, chapters: many) }
    #expect(
      try entry(0, chapters: Array(many.dropLast())).chapters.count == WatchEpisodeSendLimits.maxChapters)
    // Equal starts are non-decreasing, so a feed that repeats a chapter start is accepted.
    #expect(
      try entry(
        0,
        chapters: [
          WatchEpisodeChapter(title: "One", start: 0),
          WatchEpisodeChapter(title: "Two", start: 0),
        ]
      ).chapters.count == 2)
  }

  /// The codec, not `validate`, owns the exact byte cap: only the encoder knows the metadata cost.
  @Test func anOversizedOfferIsRejectedByTheCodec() throws {
    let entries = try (0..<WatchEpisodeSendLimits.maxOfferEntries).map {
      try entry(
        $0, title: String(repeating: "t", count: WatchProtocolVersion.maxMetadataStringBytes),
        showTitle: String(repeating: "s", count: WatchProtocolVersion.maxMetadataStringBytes))
    }
    let offer = try offer(entries: entries)
    #expect(throws: WatchProtocolCodingError.tooLarge) { try WatchWireCodec.encode(offer) }
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(
        WatchEpisodeSendOffer.self, from: Data(repeating: 0x20, count: WatchEpisodeSendOffer.maxWireBytes + 1))
    }
  }

  @Test func fittingKeepsTheLongestPrefixAndReportsWhatWasOmitted() throws {
    let entries = try (0..<WatchEpisodeSendLimits.maxOfferEntries).map {
      try entry(
        $0, title: String(repeating: "t", count: WatchProtocolVersion.maxMetadataStringBytes),
        showTitle: String(repeating: "s", count: WatchProtocolVersion.maxMetadataStringBytes))
    }
    let result = try WatchEpisodeSendOffer.fitting(
      generation: 3, watchInstallID: installID, entries: entries, sentAt: sentAt)
    #expect(!result.omitted.isEmpty)
    #expect(result.offer.entries.count + result.omitted.count == entries.count)
    #expect(result.offer.entries == Array(entries.prefix(result.offer.entries.count)))
    #expect(result.omitted == entries.dropFirst(result.offer.entries.count).map(\.selection))
    #expect(try WatchWireCodec.encode(result.offer).count <= WatchEpisodeSendOffer.maxWireBytes)
  }

  @Test func fittingKeepsAllOneHundredShortEntries() throws {
    let entries = try (0..<WatchEpisodeSendLimits.maxOfferEntries).map { try entry($0) }
    let result = try WatchEpisodeSendOffer.fitting(
      generation: 4, watchInstallID: nil, entries: entries, sentAt: sentAt)
    #expect(result.omitted.isEmpty)
    #expect(result.offer.entries.count == WatchEpisodeSendLimits.maxOfferEntries)
    let roundTripped = try WatchWireCodec.decode(
      WatchEpisodeSendOffer.self, from: WatchWireCodec.encode(result.offer))
    #expect(roundTripped == result.offer)
  }

  /// A realistic B entry carries a long title, a signed CDN URL and the episode's chapters. The
  /// 64 KiB offer cap must still hold the Watch's roughly 25-copy working set (ADR 0020 Decision 1).
  @Test func fittingKeepsAtLeastTwentyFiveRealisticEntries() throws {
    let entries = try (0..<WatchEpisodeSendLimits.maxOfferEntries).map { index in
      try entry(
        index, title: String(repeating: "t", count: 200),
        showTitle: String(repeating: "s", count: 200),
        enclosureURL: signedURL(index),
        chapters: (0..<20).map {
          try WatchEpisodeChapter(
            title: "Chapter \($0)", start: Double($0) * 60, end: Double($0) * 60 + 60)
        })
    }
    let result = try WatchEpisodeSendOffer.fitting(
      generation: 6, watchInstallID: installID, entries: entries, sentAt: sentAt)
    #expect(result.offer.entries.count >= 25)
    #expect(try WatchWireCodec.encode(result.offer).count <= WatchEpisodeSendOffer.maxWireBytes)
    #expect(result.offer.entries.first?.enclosureURL.absoluteString.utf8.count == 300)
  }

  /// A duplicate is a caller bug, so `fitting` surfaces it instead of treating it as "did not fit".
  @Test func fittingRefusesADuplicateRatherThanDroppingIt() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchEpisodeSendOffer.fitting(
        generation: 5, watchInstallID: nil, entries: [entry(0), entry(0)], sentAt: sentAt)
    }
  }

  // MARK: Selection

  @Test func nativeSelectionOnlyWrapsANativeFeedSelection() throws {
    let native = try WatchNativeSelection(feedID: "feed", episodeID: "episode")
    #expect(native.selection == .nativeFeed(feedID: "feed", episodeID: "episode"))
    #expect(native == WatchNativeSelection(.nativeFeed(feedID: "feed", episodeID: "episode")))
    #expect(WatchNativeSelection(.audiobookshelf(itemID: "book", episodeID: "episode")) == nil)
    #expect(WatchNativeSelection(.audiobookshelf(itemID: "book", episodeID: nil)) == nil)
  }

  /// The identifier rules are `WatchSelection`'s, so both directions of the wire agree.
  @Test func nativeSelectionUsesTheSelectionIdentifierRules() throws {
    for bad in ["", "https://feed.example.test/rss", "file:episode", "/episode", "epi\nsode"] {
      #expect(throws: WatchProtocolCodingError.invalidSelection) {
        try WatchNativeSelection(feedID: bad, episodeID: "episode")
      }
      #expect(throws: WatchProtocolCodingError.invalidSelection) {
        try WatchNativeSelection(feedID: "feed", episodeID: bad)
      }
    }
  }

  // MARK: Chapters

  @Test func chapterBoundsAreValidated() throws {
    #expect(try WatchEpisodeChapter(title: "Intro", start: 0, end: 30).end == 30)
    #expect(try WatchEpisodeChapter(title: "Intro", start: 0).end == nil)
    for (start, end) in [(0.0, 0.0), (10.0, 5.0), (-1.0, 10.0), (Double.nan, 10.0), (0.0, Double.infinity)] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try WatchEpisodeChapter(title: "Intro", start: start, end: end)
      }
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) { try WatchEpisodeChapter(title: "", start: 0) }
  }

  // MARK: Helpers

  private func selection(_ index: Int = 0) throws -> WatchNativeSelection {
    try WatchNativeSelection(feedID: "feed-\(index)", episodeID: "episode-\(index)")
  }

  private func audioURL(_ index: Int = 0) -> URL {
    URL(string: "https://cdn.example.test/audio/\(index).mp3")!
  }

  private func signedURL(_ index: Int) -> URL {
    let prefix = "https://cdn.example.test/audio/\(index)/"
    return URL(string: prefix + String(repeating: "u", count: 300 - prefix.utf8.count))!
  }

  private func entry(
    _ index: Int = 0, revision: UInt64 = 1, title: String = "Episode", showTitle: String = "Show",
    duration: Double? = 3_600, declaredBytes: Int64? = 40_000_000, enclosureURL: URL? = nil,
    mimeType: String = "audio/mpeg", chapters: [WatchEpisodeChapter] = [], position: Double = 0
  ) throws -> WatchEpisodeOfferEntry {
    try WatchEpisodeOfferEntry(
      selection: selection(index), revision: revision, title: title, showTitle: showTitle, duration: duration,
      declaredBytes: declaredBytes, enclosureURL: enclosureURL ?? audioURL(index), mimeType: mimeType,
      chapters: chapters, position: position, lastListenedAt: sentAt)
  }

  private func offer(
    generation: UInt64 = 1, installID: String? = "a1b2c3d4-0000-4000-8000-000000000001",
    entries: [WatchEpisodeOfferEntry] = []
  ) throws -> WatchEpisodeSendOffer {
    try WatchEpisodeSendOffer(
      generation: generation, watchInstallID: installID, entries: entries, sentAt: sentAt)
  }
}
