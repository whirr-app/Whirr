import Foundation
import Testing

@testable import ABSApi

@Suite("Detail artwork sizing")
struct DetailArtworkSizingTests {
  private static func sizing(scale: Double) -> DetailArtworkSizing {
    DetailArtworkSizing(
      fallbackDisplaySize: 272, heroSide: 300, previewEdge: 220, displayScale: scale)
  }

  @Test("the fallback is the shared high-fidelity width")
  func fallbackIsTheSharedWidth() {
    #expect(Self.sizing(scale: 3).fallbackVariant == .highFidelity(pixelWidth: 1024))
    #expect(Self.sizing(scale: 2).fallbackVariant == .highFidelity(pixelWidth: 768))
  }

  @Test(
    "the fitted width covers the hero and the preview for the cover's shape",
    arguments: [
      (2.0 / 3.0, 3.0, 660),  // portrait: the preview's 220-point width is the larger need
      (1.0, 3.0, 900),  // square: the hero's full side
      (0.9, 3.0, 810),
      (1.5, 3.0, 990),  // landscape: the preview needs 220 points of height
      (2.0, 3.0, 1024),  // capped at the fallback
      (2.0 / 3.0, 2.0, 440),
      (1.0, 2.0, 600),
    ])
  func fittedWidth(aspectRatio: Double, scale: Double, expected: Int) {
    #expect(Self.sizing(scale: scale).fitPixelWidth(aspectRatio: aspectRatio) == expected)
  }

  @Test("a nonsensical shape falls back rather than producing a width")
  func degenerateShapeFallsBack() {
    let sizing = Self.sizing(scale: 3)
    #expect(sizing.fitPixelWidth(aspectRatio: 0) == 1024)
    #expect(sizing.fitPixelWidth(aspectRatio: -1) == 1024)
    #expect(sizing.fitPixelWidth(aspectRatio: .nan) == 1024)
    #expect(sizing.fitPixelWidth(aspectRatio: .infinity) == 1024)
  }

  @Test("the fitted variant is used only for a recorded width this sizing still gives")
  func variantRequiresTheRecordedWidth() {
    let sizing = Self.sizing(scale: 3)
    #expect(sizing.variant(for: nil) == .highFidelity(pixelWidth: 1024))
    #expect(
      sizing.variant(for: CoverShape(aspectRatio: 2.0 / 3.0, fitPixelWidth: 660))
        == .detailFit(pixelWidth: 660))
    // Recorded at 2x, read at 3x: the 440-pixel file is not the one this screen needs.
    #expect(
      sizing.variant(for: CoverShape(aspectRatio: 2.0 / 3.0, fitPixelWidth: 440))
        == .highFidelity(pixelWidth: 1024))
    // A shape whose fitted width reaches the fallback stays on the fallback key.
    #expect(
      sizing.variant(for: CoverShape(aspectRatio: 2, fitPixelWidth: 1024))
        == .highFidelity(pixelWidth: 1024))
  }

  @Test("a fitted variant is requested at exactly its width")
  func fittedVariantIsNotQuantized() throws {
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("https://covers.example.test"), itemID: "item-1",
      variant: .detailFit(pixelWidth: 660), revision: .unversioned)
    #expect(try key.coverRequest().width == 660)
  }

  @Test("the index answers only for the revision a shape was measured at")
  func indexIsRevisionScoped() {
    let index = CoverShapeIndex()
    let shape = CoverShape(aspectRatio: 0.66, fitPixelWidth: 660)
    index.record(shape, itemID: "item-1", revision: ArtworkRevision("1"))

    #expect(index.shape(itemID: "item-1", revision: ArtworkRevision("1")) == shape)
    #expect(index.shape(itemID: "item-1", revision: ArtworkRevision("2")) == nil)
    #expect(index.shape(itemID: "item-2", revision: ArtworkRevision("1")) == nil)

    index.removeAll()
    #expect(index.shape(itemID: "item-1", revision: ArtworkRevision("1")) == nil)
  }
}
