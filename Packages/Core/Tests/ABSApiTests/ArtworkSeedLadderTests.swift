import Foundation
import Testing

@testable import ABSApi

@Suite("Artwork seed ladder")
struct ArtworkSeedLadderTests {
  @Test("a thumbnail or card target is seeded by the smaller widths, not only high fidelity")
  func smallerTargetsAreSeededToo() {
    let variants: [ArtworkVariant] = [
      .highFidelity(pixelWidth: 1024),
      .homeCard(pixelWidth: 420),
      .libraryThumbnail(pixelWidth: 216),
      .libraryThumbnail(pixelWidth: 132),
    ]

    #expect(
      ArtworkSeedLadder.candidates(
        for: makeKey(variant: .homeCard(pixelWidth: 420)), seedVariants: variants
      ).map(\.variant.pixelWidth) == [216, 132])
    #expect(
      ArtworkSeedLadder.candidates(
        for: makeKey(variant: .libraryThumbnail(pixelWidth: 216)), seedVariants: variants
      ).map(\.variant.pixelWidth) == [132])
  }

  @Test("the smallest target still has no candidates")
  func smallestTargetHasNoCandidates() {
    let variants: [ArtworkVariant] = [
      .homeCard(pixelWidth: 420),
      .libraryThumbnail(pixelWidth: 132),
    ]

    #expect(
      ArtworkSeedLadder.candidates(
        for: makeKey(variant: .libraryThumbnail(pixelWidth: 132)), seedVariants: variants) == [])
  }

  @Test("only strictly smaller variants are candidates")
  func onlyStrictlySmallerVariantsAreCandidates() {
    let key = makeKey(variant: .highFidelity(pixelWidth: 512))
    let variants: [ArtworkVariant] = [
      .libraryThumbnail(pixelWidth: 1024),
      .homeCard(pixelWidth: 512),
      .libraryThumbnail(pixelWidth: 256),
    ]

    #expect(
      ArtworkSeedLadder.candidates(for: key, seedVariants: variants).map(\.variant)
        == [.libraryThumbnail(pixelWidth: 256)])
  }

  @Test("candidates are ordered from largest to smallest")
  func candidatesAreOrderedFromLargestToSmallest() {
    let key = makeKey(variant: .highFidelity(pixelWidth: 1024))
    let variants: [ArtworkVariant] = [
      .libraryThumbnail(pixelWidth: 132),
      .homeCard(pixelWidth: 420),
      .libraryThumbnail(pixelWidth: 216),
      .libraryThumbnail(pixelWidth: 360),
    ]

    #expect(
      ArtworkSeedLadder.candidates(for: key, seedVariants: variants).map(\.variant.pixelWidth)
        == [420, 360, 216, 132])
  }

  @Test("variants sharing a pixel width are probed once, keeping the first")
  func variantsSharingAPixelWidthAreProbedOnceKeepingTheFirst() {
    let key = makeKey(variant: .highFidelity(pixelWidth: 1024))
    let variants: [ArtworkVariant] = [
      .homeCard(pixelWidth: 132),
      .libraryThumbnail(pixelWidth: 132),
      .libraryThumbnail(pixelWidth: 420),
      .homeCard(pixelWidth: 420),
    ]

    #expect(
      ArtworkSeedLadder.candidates(for: key, seedVariants: variants).map(\.variant)
        == [
          .libraryThumbnail(pixelWidth: 420),
          .homeCard(pixelWidth: 132),
        ])
  }

  @Test("candidate keys preserve account scope, item, and revision")
  func candidateKeysPreserveIdentity() {
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("https://books.example.test#account=42"),
      itemID: "item-42",
      variant: .highFidelity(pixelWidth: 1024),
      revision: ArtworkRevision("revision-7"))

    let candidates = ArtworkSeedLadder.candidates(
      for: key,
      seedVariants: [
        .homeCard(pixelWidth: 420),
        .libraryThumbnail(pixelWidth: 132),
      ])

    #expect(candidates.isEmpty == false)
    #expect(candidates.allSatisfy { $0.accountScope == key.accountScope })
    #expect(candidates.allSatisfy { $0.itemID == key.itemID })
    #expect(candidates.allSatisfy { $0.revision == key.revision })
  }

  @Test("RSS candidate keys preserve the RSS artwork source")
  func rssCandidateKeysPreserveSource() throws {
    let rssSource = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:7",
        artworkURL: URL(string: "https://images.example.test/show.png")!,
        feedURL: URL(string: "https://feeds.example.test/show.xml")!))
    let key = ArtworkKey(
      source: .rss(rssSource),
      itemID: "show-7",
      variant: .highFidelity(pixelWidth: 1024),
      revision: .unversioned)

    let candidates = ArtworkSeedLadder.candidates(
      for: key,
      seedVariants: [.homeCard(pixelWidth: 420), .libraryThumbnail(pixelWidth: 132)])

    #expect(candidates.map(\.variant.pixelWidth) == [420, 132])
    #expect(candidates.allSatisfy { $0.source == .rss(rssSource) })
  }

  private func makeKey(variant: ArtworkVariant) -> ArtworkKey {
    ArtworkKey(
      accountScope: ArtworkAccountScope("https://books.example.test"),
      itemID: "item-1",
      variant: variant,
      revision: ArtworkRevision("revision-1"))
  }
}
