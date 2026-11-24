import Foundation
import Testing

@testable import ABSApi

@Suite("Artwork identity")
struct ArtworkIdentityTests {
  @Test("library, search, and mini-player share the exact thumbnail variant")
  func librarySearchAndMiniPlayerConstructTheSameThumbnailVariantAtOneScale() {
    let library = ArtworkVariant.libraryThumbnail(displaySize: 44, displayScale: 3)
    let search = ArtworkVariant.libraryThumbnail(displaySize: 44, displayScale: 3)
    let miniPlayer = ArtworkVariant.libraryThumbnail(displaySize: 44, displayScale: 3)

    #expect(library == search)
    #expect(search == miniPlayer)
    #expect(library.pixelWidth == 132)
  }

  @Test("home cards remain a distinct small variant")
  func homeCardRemainsADistinctSmallVariant() {
    let thumbnail = ArtworkVariant.libraryThumbnail(displaySize: 44, displayScale: 3)
    let home = ArtworkVariant.homeCard(displaySize: 140, displayScale: 3)

    #expect(home != thumbnail)
    #expect(home.pixelWidth == 420)
  }

  @Test("only high-fidelity variants use the existing quantized ladder")
  func highFidelityVariantsRetainTheExistingQuantizedLadder() {
    #expect(ArtworkVariant.libraryThumbnail(displaySize: 200, displayScale: 3).pixelWidth == 600)
    #expect(ArtworkVariant.homeCard(displaySize: 200, displayScale: 3).pixelWidth == 600)
    #expect(ArtworkVariant.highFidelity(displaySize: 200, displayScale: 3).pixelWidth == 768)
  }

  @Test("account/server scope and revision are part of prepared artwork identity")
  func scopeAndRevisionSeparatePreparedKeys() {
    let variant = ArtworkVariant.libraryThumbnail(displaySize: 44, displayScale: 3)
    let base = ArtworkKey(
      accountScope: ArtworkAccountScope("https://one.example"),
      itemID: "item-1",
      variant: variant,
      revision: ArtworkRevision("1"))

    #expect(
      base
        != ArtworkKey(
          accountScope: ArtworkAccountScope("https://two.example"),
          itemID: "item-1",
          variant: variant,
          revision: ArtworkRevision("1")))
    #expect(
      base
        != ArtworkKey(
          accountScope: base.accountScope,
          itemID: "item-1",
          variant: variant,
          revision: ArtworkRevision("2")))
  }

  @Test("an ABS revision is the server updatedAt in epoch milliseconds, unversioned when absent")
  func revisionDerivesFromServerUpdatedAt() {
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000.123)

    #expect(ArtworkRevision(serverUpdatedAt: updatedAt) == ArtworkRevision("1700000000123"))
    #expect(ArtworkRevision(serverUpdatedAt: nil) == .unversioned)
  }

  @Test("every whole millisecond survives the Double round trip to the same revision")
  func revisionIsExactForWholeMilliseconds() {
    // Server rows decode `updatedAt` as `millis / 1000`; persisted rows come back through GRDB's
    // millisecond text. Either path can land a hair below the millisecond, and a truncating
    // conversion would then key one cover two ways.
    for millis in Int64(1_700_000_000_000)...Int64(1_700_000_002_000) {
      let decoded = Date(timeIntervalSince1970: Double(millis) / 1000)
      #expect(ArtworkRevision(serverUpdatedAt: decoded) == ArtworkRevision(String(millis)))
    }
  }

  @Test("an ABS key's cover request carries the key's revision")
  func coverRequestCarriesKeyRevision() throws {
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("https://one.example"),
      itemID: "item-1",
      variant: .libraryThumbnail(pixelWidth: 132),
      revision: ArtworkRevision("42"))

    #expect(try key.coverRequest().revision == ArtworkRevision("42"))
  }

  @Test("RSS URL normalization is stable and provider identity isolates the same item id")
  func rssIdentityNormalizesAndSeparatesProviders() throws {
    let rssSource = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:7",
        artworkURL: URL(string: "HTTPS://Images.Example.test:443/show.png#fragment")!,
        feedURL: URL(string: "https://feeds.example.test/show.xml")!))
    #expect(rssSource.normalizedArtworkURL == "https://images.example.test/show.png")

    let variant = ArtworkVariant.homeCard(displaySize: 140, displayScale: 2)
    let rss = ArtworkKey(
      source: .rss(rssSource), itemID: "same-id", variant: variant, revision: .unversioned)
    let abs = ArtworkKey(
      accountScope: ArtworkAccountScope("rss|rss:7|https://images.example.test/show.png"),
      itemID: "same-id", variant: variant, revision: .unversioned)

    #expect(rss != abs)
    #expect(rss.accountScope != abs.accountScope)
  }

  @Test("provider facade routes RSS without consulting the ABS provider")
  func facadeRoutesByProvider() async throws {
    let abs = RecordingArtworkProvider(source: .audiobookshelf(ArtworkAccountScope("abs")))
    let rssSource = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:3",
        artworkURL: URL(string: "https://images.example.test/show.jpg")!,
        feedURL: URL(string: "https://feeds.example.test/show.xml")!))
    let rss = RecordingArtworkProvider(source: .rss(rssSource))
    let facade = ProviderArtworkClient(abs: abs, rss: rss)
    let key = ArtworkKey(
      source: .rss(rssSource), itemID: "same-id",
      variant: .libraryThumbnail(pixelWidth: 88), revision: .unversioned)

    _ = try await facade.fetch(key)

    #expect(await abs.fetchCount == 0)
    #expect(await rss.fetchCount == 1)
  }
}

private actor RecordingArtworkProvider: ArtworkServing {
  nonisolated let defaultSource: ArtworkSource?
  private(set) var fetchCount = 0

  init(source: ArtworkSource) {
    defaultSource = source
  }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    fetchCount += 1
    return CoverImageResult(data: Data([1]), contentType: "image/png")
  }

  func data(for key: ArtworkKey) -> Data? { nil }
  func needsRefresh(_ key: ArtworkKey) -> Bool { true }
}
