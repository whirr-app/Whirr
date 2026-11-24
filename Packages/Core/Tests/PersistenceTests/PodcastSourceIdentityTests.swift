import ABSApi
import Foundation
import Persistence
import Testing

@Suite struct PodcastSourceIdentityTests {
  @Test("validated construction rejects identities that cannot round-trip")
  func validatedConstructionRejectsInvalidValues() throws {
    #expect(PodcastSourceIdentity.abs(itemId: "") == nil)
    #expect(PodcastSourceIdentity.abs(itemId: "rss:7") == nil)
    #expect(PodcastSourceIdentity.abs(itemId: "RSS:7") == nil)
    #expect(PodcastSourceIdentity.rss(feedId: 0) == nil)
    #expect(PodcastSourceIdentity.rss(feedId: -1) == nil)

    let abs = try #require(PodcastSourceIdentity.abs(itemId: "li_abc123"))
    let rss = try #require(PodcastSourceIdentity.rss(feedId: 7))
    #expect(abs.source == .abs(itemId: "li_abc123"))
    #expect(rss.source == .rss(feedId: 7))
    #expect(abs.itemId == "li_abc123")
    #expect(rss.itemId == "rss:7")
  }

  @Test("listening identities cannot carry an invalid native feed id")
  func listeningIdentityFailsClosedForInvalidRSSFeedIDs() throws {
    #expect(ListeningIdentity.rssEpisode(feedID: 0, episodeID: "episode") == nil)
    #expect(ListeningIdentity.rssEpisode(feedID: -1, episodeID: "episode") == nil)

    let identity = try #require(
      ListeningIdentity.rssEpisode(feedID: 7, episodeID: "episode"))
    #expect(identity.itemID == "rss:7")
    #expect(identity.source == .rssEpisode(feedID: 7, episodeID: "episode"))
  }

  @Test("listening identities reject malformed or source-colliding ABS identities")
  func listeningIdentityValidatesEverySource() throws {
    #expect(ListeningIdentity.audiobook(itemID: "") == nil)
    #expect(ListeningIdentity.audiobook(itemID: "rss:7") == nil)
    #expect(ListeningIdentity.audiobook(itemID: "RSS:7") == nil)
    #expect(ListeningIdentity.podcastEpisode(itemID: "", episodeID: "episode") == nil)
    #expect(ListeningIdentity.podcastEpisode(itemID: "rss:7", episodeID: "episode") == nil)
    #expect(ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "") == nil)
    #expect(ListeningIdentity.rssEpisode(feedID: 7, episodeID: "") == nil)

    let book = try #require(ListeningIdentity.audiobook(itemID: "book"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode"))
    #expect(book.itemID == "book")
    #expect(episode.itemID == "show")
    #expect(episode.episodeID == "episode")
  }

  @Test("a row's item and episode ids resolve to the listening identity its source owns")
  func resolvesListeningIdentityBySource() {
    #expect(ListeningIdentity.resolving(itemID: "book") == .audiobook(itemID: "book"))
    #expect(
      ListeningIdentity.resolving(itemID: "show", episodeID: "episode")
        == .podcastEpisode(itemID: "show", episodeID: "episode"))
    #expect(
      ListeningIdentity.resolving(itemID: "rss:7", episodeID: "guid-1")
        == .rssEpisode(feedID: 7, episodeID: "guid-1"))
    // A whole native show is never a listening identity, and a malformed reserved id is neither
    // source: both fail closed exactly as the per-source factories do.
    #expect(ListeningIdentity.resolving(itemID: "rss:7") == nil)
    #expect(ListeningIdentity.resolving(itemID: "rss:007", episodeID: "episode") == nil)
    #expect(ListeningIdentity.resolving(itemID: "rss:7", episodeID: "") == nil)
  }

  @Test("strictly decodes serialized podcast source identities")
  func decodesMatrix() {
    let cases: [(name: String, input: String, expected: PodcastSourceIdentity?)] = [
      ("rss one", "rss:1", PodcastSourceIdentity.rss(feedId: 1)),
      ("rss forty-two", "rss:42", PodcastSourceIdentity.rss(feedId: 42)),
      ("rss max", "rss:9223372036854775807", PodcastSourceIdentity.rss(feedId: Int64.max)),
      ("empty rss", "rss:", nil),
      ("zero", "rss:0", nil),
      ("leading zero", "rss:007", nil),
      ("negative", "rss:-3", nil),
      ("overflow", "rss:9223372036854775808", nil),
      ("non-digit suffix", "rss:12a", nil),
      ("full-width digit", "rss:１２", nil),
      ("uppercase prefix", "RSS:12", nil),
      ("mixed-case prefix", "Rss:12", nil),
      ("empty id", "", nil),
      ("ABS library id", "li_abc123", PodcastSourceIdentity.abs(itemId: "li_abc123")),
      ("ABS UUID", "some-uuid", PodcastSourceIdentity.abs(itemId: "some-uuid")),
      ("near-miss prefix", "rssX:12", PodcastSourceIdentity.abs(itemId: "rssX:12")),
      ("single character", "r", PodcastSourceIdentity.abs(itemId: "r")),
    ]

    for testCase in cases {
      #expect(
        PodcastSourceIdentity(itemId: testCase.input) == testCase.expected,
        "\(testCase.name): \(testCase.input)"
      )
    }
  }

  @Test("encoded identities decode back to themselves")
  func roundTrips() throws {
    let values = try [
      PodcastSourceIdentity.rss(feedId: 1), PodcastSourceIdentity.rss(feedId: Int64.max),
      PodcastSourceIdentity.abs(itemId: "li_abc123"),
      PodcastSourceIdentity.abs(itemId: "some-uuid"), PodcastSourceIdentity.abs(itemId: "rssX:12"),
    ].map {
      try #require($0)
    }

    for value in values {
      #expect(PodcastSourceIdentity(itemId: value.itemId) == value, "\(value)")
    }
  }

  @Test("detects reserved prefixes case-insensitively")
  func detectsReservedPrefixes() {
    let expected: [(String, Bool)] = [
      ("rss:12", true), ("rss:", true), ("RSS:12", true), ("rSs:junk", true),
      ("rss", false), ("rssX:12", false), ("", false), ("li_abc", false),
    ]

    for (id, result) in expected {
      #expect(PodcastSourceIdentity.hasReservedPrefix(id) == result, "\(id)")
    }
  }

  @Test("deep-link escaping preserves source identity")
  func deepLinkEscapingRoundTrips() throws {
    let values = try [
      PodcastSourceIdentity.rss(feedId: 12), PodcastSourceIdentity.abs(itemId: "some-id_with"),
    ].map {
      try #require($0)
    }

    for value in values {
      let escaped = try #require(
        value.itemId.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
      let restored = try #require(escaped.removingPercentEncoding)
      #expect(restored == value.itemId, "restored serialized id for \(value)")
      #expect(PodcastSourceIdentity(itemId: restored) == value, "decoded identity for \(value)")
    }

    #expect(
      "rss:12".addingPercentEncoding(withAllowedCharacters: .alphanumerics) == "rss%3A12")
  }

  @Test("typed RSS artwork identity shares the serialized podcast cache key")
  func typedArtworkIdentityMatchesPodcastSourceIdentity() throws {
    let feedID: Int64 = 7
    let artworkURL = try #require(URL(string: "https://images.example.test/show.png"))
    let feedURL = try #require(URL(string: "https://feeds.example.test/show.xml"))
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
    let typedSource = try #require(
      RSSArtworkSource(feedID: feedID, artworkURL: artworkURL, feedURL: feedURL))
    let serializedSource = try #require(
      RSSArtworkSource(feedIdentity: itemID, artworkURL: artworkURL, feedURL: feedURL))
    let variant = ArtworkVariant.libraryThumbnail(pixelWidth: 88)

    let typedKey = ArtworkKey(
      source: .rss(typedSource), itemID: itemID, variant: variant, revision: .unversioned)
    let serializedKey = ArtworkKey(
      source: .rss(serializedSource), itemID: itemID, variant: variant, revision: .unversioned)

    #expect(typedKey == serializedKey)
    #expect(typedSource.feedIdentity == itemID)
  }
}
