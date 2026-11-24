import Foundation
import PodcastFeeds
import Testing

@Suite("Episode identity")
struct EpisodeIdentityTests {
  private let enclosure = ParsedEnclosure(
    url: URL(string: "https://example.com/e.mp3")!, type: "audio/mpeg", lengthBytes: nil
  )

  private func item(
    guid: String? = nil, enclosure: ParsedEnclosure? = nil, pubDate: String? = nil
  ) -> ParsedFeedItem {
    ParsedFeedItem(
      guid: guid, title: nil, enclosure: enclosure, pubDate: pubDate, durationText: nil,
      synopsis: nil, seasonNumber: nil, episodeNumber: nil
    )
  }

  @Test("selects unique GUIDs and enclosure alternates")
  func uniqueGUIDs() {
    let items = [
      item(guid: "one", enclosure: enclosure, pubDate: "date"),
      item(guid: "two"),
      item(guid: "three", enclosure: enclosure),
    ]
    let identities = EpisodeIdentityPolicy.identities(for: items)

    #expect(identities.count == 3)
    #expect(identities.allSatisfy { $0?.source == .guid })
    #expect(identities[0]?.key == "guid:one")
    #expect(identities[1]?.key == "guid:two")
    #expect(identities[2]?.key == "guid:three")
    #expect(identities[0]?.alternateKey?.hasPrefix("sha256:") == true)
    #expect(identities[1]?.alternateKey == nil)
    #expect(identities[2]?.alternateKey?.hasPrefix("sha256:") == true)
  }

  @Test("duplicate and missing GUIDs fall back independently")
  func fallback() {
    let items = [
      item(guid: "duplicate", enclosure: enclosure),
      item(guid: " duplicate ", enclosure: enclosure),
      item(guid: "unique"),
      item(guid: "   "),
      item(),
    ]
    let identities = EpisodeIdentityPolicy.identities(for: items)

    #expect(identities[0]?.source == .enclosure)
    #expect(identities[1]?.source == .enclosure)
    #expect(identities[2] == EpisodeIdentity(key: "guid:unique", source: .guid, alternateKey: nil))
    #expect(identities[3] == nil)
    #expect(identities[4] == nil)
  }

  @Test("pins enclosure hash and publication-date behavior")
  func enclosureKeys() {
    // SHA-256 of the enclosure URL, newline, and `unix-ms:1704067200000`.
    let canonical = "sha256:9ac552c5da5a12c3188841681b648d5487b6de6a20bab7b16e5898ebba570237"
    let legacy = "sha256:f7fa7bb6cf830a5d3fd34e9e4dff2a8fbcba517b160be74f091003315b2721c8"
    let dated = item(enclosure: enclosure, pubDate: "Mon, 01 Jan 2024 00:00:00 GMT")
    let missingDate = item(enclosure: enclosure)
    let emptyDate = item(enclosure: enclosure, pubDate: "")
    let differentDate = item(enclosure: enclosure, pubDate: "Tue, 02 Jan 2024 00:00:00 GMT")
    let datedIdentity = EpisodeIdentityPolicy.identities(for: [dated])[0]

    #expect(datedIdentity?.key == canonical)
    #expect(datedIdentity?.alternateKey == legacy)
    #expect(
      EpisodeIdentityPolicy.identities(for: [missingDate])[0]?.key
        == EpisodeIdentityPolicy.identities(for: [emptyDate])[0]?.key)
    #expect(
      EpisodeIdentityPolicy.identities(for: [missingDate])[0]?.key
        != EpisodeIdentityPolicy.identities(for: [differentDate])[0]?.key)
  }

  @Test("GUID changes retain the legacy enclosure alternate during migration")
  func changedGUIDMigration() throws {
    let rawDate = "Mon, 01 Jan 2024 00:00:00 GMT"
    let fallback = try #require(
      EpisodeIdentityPolicy.identities(
        for: [item(enclosure: enclosure, pubDate: rawDate)])[0])
    let legacyKey = try #require(fallback.alternateKey)
    let stored = EpisodeIdentity(key: "guid:old", source: .guid, alternateKey: legacyKey)
    let incoming = try #require(
      EpisodeIdentityPolicy.identities(
        for: [item(guid: "new", enclosure: enclosure, pubDate: rawDate)])[0])

    #expect(incoming.alternateKey == legacyKey)
    #expect(EpisodeIdentityPolicy.sameEpisode(stored, incoming))
  }

  @Test("equivalent publication-date spellings share one fallback identity")
  func equivalentPublicationDates() throws {
    let spellings = [
      "Mon, 1 Jan 2024 00:00:00 GMT",
      "Mon, 01 Jan 24 01:00:00 +0100",
      "2024-01-01T00:00:00Z",
    ]
    let identities = spellings.map {
      EpisodeIdentityPolicy.identities(for: [item(enclosure: enclosure, pubDate: $0)])[0]
    }
    let primary = try #require(identities[0]?.key)

    #expect(identities.allSatisfy { $0?.key == primary })
    #expect(Set(identities.compactMap { $0?.alternateKey }).count == spellings.count)
  }

  @Test("unparseable publication dates retain their raw fallback semantics")
  func unparseablePublicationDates() {
    let first = EpisodeIdentityPolicy.identities(
      for: [item(enclosure: enclosure, pubDate: " release-day ")])[0]
    let same = EpisodeIdentityPolicy.identities(
      for: [item(enclosure: enclosure, pubDate: "release-day")])[0]
    let different = EpisodeIdentityPolicy.identities(
      for: [item(enclosure: enclosure, pubDate: "another-day")])[0]

    #expect(first?.key == same?.key)
    #expect(first?.key != different?.key)
    #expect(first?.alternateKey == nil)
  }

  @Test("preserves nil indexes when an item has no identity material")
  func indexAlignment() {
    let identities = EpisodeIdentityPolicy.identities(for: [item(), item(guid: "kept")])
    #expect(identities.count == 2)
    #expect(identities[0] == nil)
    #expect(identities[1]?.key == "guid:kept")
  }

  @Test("matches identity drift through alternate enclosure keys")
  func sameEpisodeMatrix() {
    let enclosureKey = "sha256:enclosure"
    let guidA = EpisodeIdentity(key: "guid:a", source: .guid, alternateKey: enclosureKey)
    let guidB = EpisodeIdentity(key: "guid:b", source: .guid, alternateKey: enclosureKey)
    let bare = EpisodeIdentity(key: enclosureKey, source: .enclosure, alternateKey: nil)
    let other = EpisodeIdentity(key: "guid:other", source: .guid, alternateKey: "sha256:other")

    #expect(EpisodeIdentityPolicy.sameEpisode(guidA, guidA))
    #expect(EpisodeIdentityPolicy.sameEpisode(guidA, guidB))
    #expect(EpisodeIdentityPolicy.sameEpisode(guidA, bare))
    #expect(EpisodeIdentityPolicy.sameEpisode(bare, guidA))
    #expect(EpisodeIdentityPolicy.sameEpisode(bare, bare))
    #expect(!EpisodeIdentityPolicy.sameEpisode(guidA, other))
    #expect(
      !EpisodeIdentityPolicy.sameEpisode(
        bare, EpisodeIdentity(key: "sha256:other", source: .enclosure, alternateKey: nil)))
  }
}
