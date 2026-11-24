import Foundation
import Testing

@testable import WatchProtocol

/// The one URL the wire carries, and the offer-entry fields B adds: the enclosure the Watch
/// downloads itself, the feed's declared length and the episode's chapters (ADR 0020 Decision 1).
struct WatchEpisodeEnclosureTests {
  private let sentAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

  // MARK: Enclosure URL

  @Test func enclosureURLAcceptsAbsoluteHTTPAndHTTPS() throws {
    for text in [
      "https://cdn.example.test/audio/episode.mp3",
      "http://cdn.example.test/audio/episode.mp3",
      "HTTPS://cdn.example.test/audio/episode.mp3?sig=abc#t=10",
      "https://cdn.example.test:8443/audio.mp3",
    ] {
      let url = try #require(URL(string: text))
      try WatchEnclosureURL.validate(url)
      #expect(WatchEnclosureURL.isValid(url))
    }
  }

  @Test func enclosureURLRejectsWhatABackgroundSessionCannotFetch() throws {
    for text in [
      "/audio/episode.mp3",
      "episode.mp3",
      "file:///tmp/episode.mp3",
      "ftp://cdn.example.test/episode.mp3",
      "https://user@cdn.example.test/episode.mp3",
      "https://user:password@cdn.example.test/episode.mp3",
      "https://@cdn.example.test/episode.mp3",
    ] {
      let url = try #require(URL(string: text), "\(text) should parse")
      #expect(throws: WatchProtocolCodingError.invalidValue) { try WatchEnclosureURL.validate(url) }
      #expect(WatchEnclosureURL.isValid(url) == false)
    }

    // A scheme with no authority has no host at all.
    var hostless = URLComponents()
    hostless.scheme = "https"
    hostless.path = "/episode.mp3"
    let hostlessURL = try #require(hostless.url)
    #expect(hostlessURL.host?.isEmpty ?? true)
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchEnclosureURL.validate(hostlessURL)
    }
  }

  @Test func enclosureURLIsBoundedByItsOwnByteCap() throws {
    let prefix = "https://cdn.example.test/"
    let cap = WatchEpisodeSendLimits.maxEnclosureURLBytes
    let atCap = try #require(URL(string: prefix + String(repeating: "u", count: cap - prefix.utf8.count)))
    #expect(atCap.absoluteString.utf8.count == cap)
    try WatchEnclosureURL.validate(atCap)

    let overCap = try #require(URL(string: atCap.absoluteString + "u"))
    #expect(throws: WatchProtocolCodingError.oversizedMetadata) {
      try WatchEnclosureURL.validate(overCap)
    }
  }

  /// The no-URLs-in-text rule still applies to every string field; only the typed field may carry
  /// one (ADR 0020 Decision 1).
  @Test func textFieldsStillRefuseAURL() throws {
    #expect(throws: WatchProtocolCodingError.forbiddenMetadata) {
      try WatchEpisodeOfferEntry(
        selection: WatchNativeSelection(feedID: "feed", episodeID: "episode"), revision: 1,
        title: "https://cdn.example.test/episode.mp3", showTitle: "Show", duration: 60,
        declaredBytes: nil, enclosureURL: URL(string: "https://cdn.example.test/e.mp3")!,
        mimeType: "audio/mpeg", position: 0, lastListenedAt: nil)
    }
  }

  // MARK: Offer entry

  @Test func offerEntryRoundTripsItsEnclosureFields() throws {
    let entry = try WatchEpisodeOfferEntry(
      selection: WatchNativeSelection(feedID: "feed", episodeID: "episode"), revision: 3,
      title: "Episode", showTitle: "Show", duration: 3_600, declaredBytes: 41_234_567,
      enclosureURL: URL(string: "https://cdn.example.test/a/b.mp3?sig=abc")!, mimeType: "audio/mpeg",
      chapters: [
        try WatchEpisodeChapter(title: "Intro", start: 0, end: 30),
        try WatchEpisodeChapter(title: "Main", start: 30),
      ], position: 12, lastListenedAt: sentAt)
    let offer = try WatchEpisodeSendOffer(
      generation: 2, watchInstallID: nil, entries: [entry], sentAt: sentAt)
    let decoded = try WatchProtocolFixtures.roundTrip(offer)
    #expect(decoded == offer)
    let decodedEntry = try #require(decoded.entries.first)
    #expect(decodedEntry.enclosureURL.absoluteString == "https://cdn.example.test/a/b.mp3?sig=abc")
    #expect(decodedEntry.declaredBytes == 41_234_567)
    #expect(decodedEntry.chapters.map(\.title) == ["Intro", "Main"])
  }

  @Test func absentChaptersAndDeclaredLengthDecodeAsEmptyAndUnknown() throws {
    let entry = try WatchEpisodeOfferEntry(
      selection: WatchNativeSelection(feedID: "feed", episodeID: "episode"), revision: 1,
      title: "Episode", showTitle: "Show", duration: 60, declaredBytes: 1_000,
      enclosureURL: URL(string: "http://cdn.example.test/e.mp3")!, mimeType: "audio/mpeg",
      chapters: [try WatchEpisodeChapter(title: "One", start: 0)], position: 0, lastListenedAt: nil)
    let offer = try WatchEpisodeSendOffer(
      generation: 1, watchInstallID: nil, entries: [entry], sentAt: sentAt)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(offer)) as? [String: Any])
    var entries = try #require(object["entries"] as? [[String: Any]])
    #expect(entries.count == 1)
    entries[0].removeValue(forKey: "chapters")
    entries[0].removeValue(forKey: "declaredBytes")
    object["entries"] = entries
    let decoded = try WatchWireCodec.decode(
      WatchEpisodeSendOffer.self, from: try JSONSerialization.data(withJSONObject: object))
    let decodedEntry = try #require(decoded.entries.first)
    #expect(decodedEntry.chapters.isEmpty)
    #expect(decodedEntry.declaredBytes == nil)
  }

  @Test func anEntryWithoutItsEnclosureURLIsRejected() throws {
    let entry = try WatchEpisodeOfferEntry(
      selection: WatchNativeSelection(feedID: "feed", episodeID: "episode"), revision: 1,
      title: "Episode", showTitle: "Show", duration: 60, declaredBytes: 1_000,
      enclosureURL: URL(string: "https://cdn.example.test/e.mp3")!, mimeType: "audio/mpeg",
      position: 0, lastListenedAt: nil)
    let offer = try WatchEpisodeSendOffer(
      generation: 1, watchInstallID: nil, entries: [entry], sentAt: sentAt)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(offer)) as? [String: Any])
    var entries = try #require(object["entries"] as? [[String: Any]])
    entries[0].removeValue(forKey: "enclosureURL")
    object["entries"] = entries
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try WatchWireCodec.decode(WatchEpisodeSendOffer.self, from: data) }
  }
}
