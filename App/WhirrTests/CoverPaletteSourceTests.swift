import ABSApi
import Foundation
import Testing

@testable import Whirr

/// Pins that every palette surface extracts from one cover, so the colour a book saves does not
/// depend on which screen saw it first.
@MainActor
@Suite struct CoverPaletteSourceTests {
  private static let scope = ArtworkAccountScope("https://source.example.test#account=1")
  private static let revision = ArtworkRevision("rev-1")

  private static func key(_ variant: ArtworkVariant) -> ArtworkKey {
    ArtworkKey(accountScope: scope, itemID: "item", variant: variant, revision: revision)
  }

  private static let thumbnail = key(.libraryThumbnail(pixelWidth: 132))
  private static let hero = key(.highFidelity(pixelWidth: 4_096))
  private static var card: ArtworkKey { CoverPaletteSource.cardKey(for: thumbnail) }

  @Test("The palette source is the same artwork's home card")
  func cardKeyKeepsTheArtwork() {
    let card = CoverPaletteSource.cardKey(for: Self.hero)
    #expect(card.source == Self.hero.source)
    #expect(card.itemID == Self.hero.itemID)
    #expect(card.revision == Self.hero.revision)
    #expect(card.variant == .homeCard(pixelWidth: CoverPaletteSource.cardPixelWidth))
    #expect(CoverPaletteSource.cardKey(for: Self.thumbnail) == card)
  }

  @Test("Only a cover at least the card's size stands in for it")
  func standInNeedsTheCardsSize() {
    #expect(CoverPaletteSource.canStandIn(Self.hero, for: Self.card))
    #expect(CoverPaletteSource.canStandIn(Self.card, for: Self.card))
    #expect(!CoverPaletteSource.canStandIn(Self.thumbnail, for: Self.card))
  }

  @Test("A thumbnail surface reads the cached card, never its own thumbnail")
  func thumbnailSurfaceReadsTheCard() async {
    let thumbnailOnly = SourceArtworkProvider(cached: [Self.thumbnail: Data([1])])
    let missing = CoverPaletteService.CoverBytes.paletteSource(
      displayed: Self.thumbnail, coverClient: thumbnailOnly)
    #expect(await missing.cached() == nil)

    let both = SourceArtworkProvider(cached: [Self.thumbnail: Data([1]), Self.card: Data([2])])
    let present = CoverPaletteService.CoverBytes.paletteSource(
      displayed: Self.thumbnail, coverClient: both)
    #expect(await present.cached() == Data([2]))
  }

  @Test("A large surface prefers the cached card and falls back to its own cover")
  func largeSurfacePrefersTheCard() async {
    let both = SourceArtworkProvider(cached: [Self.hero: Data([3]), Self.card: Data([2])])
    let preferred = CoverPaletteService.CoverBytes.paletteSource(
      displayed: Self.hero, coverClient: both)
    #expect(await preferred.cached() == Data([2]))

    let heroOnly = SourceArtworkProvider(cached: [Self.hero: Data([3])])
    let fallback = CoverPaletteService.CoverBytes.paletteSource(
      displayed: Self.hero, coverClient: heroOnly)
    #expect(await fallback.cached() == Data([3]))
  }

  /// The expanded player keys its palette on the cover it draws, so a cold open joins that
  /// cover's own fetch instead of staying neutral until some other surface writes the row.
  @Test("The expanded player's palette key is its drawn cover, which stands in for the card")
  func expandedPlayerPaletteKeyIsItsDrawnCover() {
    let client = SourceArtworkProvider(cached: [:])
    let source = ArtworkSource.audiobookshelf(Self.scope)
    for scale: CGFloat in [2, 3] {
      let key = ExpandedPlayerView.paletteArtworkKey(
        itemID: "item", coverClient: client, source: source, displayScale: scale,
        revision: Self.revision)
      let drawn = CoverImageView.artworkKey(
        itemID: "item", client: client, source: source,
        displaySize: ExpandedPlayerView.artworkRequestSize, displayScale: scale,
        role: .highFidelity, revision: Self.revision)
      #expect(key == drawn)
      #expect(CoverPaletteSource.canStandIn(key, for: CoverPaletteSource.cardKey(for: key)))
    }
  }
}

private actor SourceArtworkProvider: ArtworkServing {
  nonisolated let defaultSource: ArtworkSource? = nil
  let cached: [ArtworkKey: Data]

  init(cached: [ArtworkKey: Data]) {
    self.cached = cached
  }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    throw APIError.notFound
  }

  func data(for key: ArtworkKey) async -> Data? { cached[key] }

  func needsRefresh(_ key: ArtworkKey) async -> Bool { false }
}
