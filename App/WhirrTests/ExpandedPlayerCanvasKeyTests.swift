import ABSApi
import DesignSystem
import Foundation
import SwiftUI
import Testing

@testable import Whirr

/// The expanded player's ambient canvas is latched per drawn cover, not per item: the episodes of
/// one followed show share an item id and may each draw their own image, so an auto-advance must
/// re-key the latch and read only the new image's palette.
@MainActor
@Suite struct ExpandedPlayerCanvasKeyTests {
  private static let itemID = "rss:42/guid"
  nonisolated private static let firstImageByte: UInt8 = 0x0A
  nonisolated private static let secondImageByte: UInt8 = 0x0B

  nonisolated static let samplesA = CoverPaletteSamples(
    average: CoverRGBA(red: 0.85, green: 0.2, blue: 0.2),
    dominant: [CoverRGBA(red: 0.85, green: 0.2, blue: 0.2, weight: 0.9)])
  nonisolated static let samplesB = CoverPaletteSamples(
    average: CoverRGBA(red: 0.15, green: 0.3, blue: 0.8),
    dominant: [CoverRGBA(red: 0.15, green: 0.3, blue: 0.8, weight: 0.9)])
  static let paletteA = CoverAmbientPalette.palette(from: samplesA)
  static let paletteB = CoverAmbientPalette.palette(from: samplesB)

  // MARK: Latch keys

  @Test func differentEpisodeImagesOfOneShowGetDifferentLatchKeys() throws {
    let first = try Self.identity(Self.episodeImage("ep-a.jpg"))
    let second = try Self.identity(Self.episodeImage("ep-b.jpg"))

    #expect(first.itemID == second.itemID)
    #expect(first.rowID != second.rowID)
    #expect(
      ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: first)
        != ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: second))
  }

  @Test func episodesSharingAnImageOrDrawingTheShowKeepOneLatchKey() throws {
    let shared = Self.episodeImage("shared.jpg")
    let sharedAgain = try Self.identity(shared)
    let sharedThird = try Self.identity(shared)
    let drawingShow = try Self.identity(Self.showImage())
    let drawingShowAgain = try Self.identity(Self.showImage())

    #expect(
      ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: sharedAgain)
        == ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: sharedThird))
    #expect(drawingShow.rowID == Self.itemID)
    #expect(
      ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: drawingShow)
        == ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: drawingShowAgain))
  }

  /// The item's load flips the identity from provisional to resolved and may settle its revision;
  /// neither is a different image, so neither may re-key the latch and re-read the colour.
  @Test func aProvisionalIdentityAndItsLoadedFormKeepOneLatchKey() throws {
    let image = Self.episodeImage("ep-a.jpg")
    let provisional = try Self.identity(image, isProvisional: true)
    let loaded = try Self.identity(image, revision: "settled-revision")
    let loadedAgain = try Self.identity(image)

    #expect(provisional.isProvisional)
    #expect(loaded.isProvisional == false)
    #expect(
      ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: provisional)
        == ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: loaded))
    #expect(
      ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: loaded)
        == ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: loadedAgain))
  }

  // MARK: Palette lookup

  @Test func aLoadedIdentityWithAMemoryPaletteReturnsIt() async throws {
    let service = Self.service()
    let identity = try Self.identity(Self.episodeImage("ep-a.jpg"))
    service.show(identity)
    await Self.request(identity, byte: Self.firstImageByte, in: service)

    #expect(ExpandedPlayerView.canvasPalette(for: identity, in: service) == Self.paletteA)
  }

  /// The regression: at the first body after an advance the service still shows the previous
  /// episode's image for this item. A loaded identity must not borrow that colour.
  @Test func aLoadedIdentityNeverBorrowsAnotherIdentityOfItsItem() async throws {
    let service = Self.service()
    let previous = try Self.identity(Self.episodeImage("ep-a.jpg"))
    let next = try Self.identity(Self.episodeImage("ep-b.jpg"))
    service.show(previous)
    await Self.request(previous, byte: Self.firstImageByte, in: service)

    #expect(service.palette(forItem: Self.itemID) == Self.paletteA)
    #expect(ExpandedPlayerView.canvasPalette(for: next, in: service) == nil)
  }

  @Test func aProvisionalIdentityFallsBackToTheItemsShownPalette() async throws {
    let service = Self.service()
    let shown = try Self.identity(Self.episodeImage("ep-a.jpg"))
    let provisional = try Self.identity(Self.episodeImage("ep-b.jpg"), isProvisional: true)
    service.show(shown)
    await Self.request(shown, byte: Self.firstImageByte, in: service)

    #expect(service.palette(for: provisional) == nil)
    #expect(ExpandedPlayerView.canvasPalette(for: provisional, in: service) == Self.paletteA)
  }

  // MARK: End to end

  @Test func anAdvanceToASiblingEpisodeDropsThePreviousEpisodesColour() async throws {
    let service = Self.service()
    let first = try Self.identity(Self.episodeImage("ep-a.jpg"))
    let second = try Self.identity(Self.episodeImage("ep-b.jpg"))
    let latch = ExpandedPlayerView.makeCanvasLatch()

    service.show(first)
    await Self.request(first, byte: Self.firstImageByte, in: service)
    #expect(
      Self.resolve(latch, identity: first, in: service)
        == Self.paletteA.ambientAppearance.canvas(for: .dark))

    // The advance: the artwork task has not run, so the item still shows the first image.
    #expect(service.palette(forItem: Self.itemID) == Self.paletteA)
    let advanced = Self.resolve(latch, identity: second, in: service)
    #expect(advanced == CoverAmbientPalette.fallbackCanvas(for: .dark))
    #expect(latch.palette == nil)
    #expect(latch.adoptionGeneration == 0)

    // The second episode's palette lands, and the provisional selection adopts it.
    service.show(second)
    await Self.request(second, byte: Self.secondImageByte, in: service)
    let adopted = Self.resolve(latch, identity: second, in: service)
    #expect(adopted == Self.paletteB.ambientAppearance.canvas(for: .dark))
    #expect(latch.adoptionGeneration == 1)
  }

  // MARK: Fixtures

  private static func showImage() throws -> ArtworkSource {
    let source = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:42", artworkURL: URL(string: "https://img.test/show.jpg")!))
    return .rss(source)
  }

  private static func episodeImage(_ name: String) -> ArtworkSource {
    // The feed and host are fixed test literals, so the force unwrap cannot trap.
    let source = RSSArtworkSource(
      feedIdentity: "rss:42", artworkURL: URL(string: "https://img.test/\(name)")!)!
    return .rss(source)
  }

  private static func identity(
    _ image: ArtworkSource, revision: String = "revision-1", isProvisional: Bool = false
  ) throws -> CoverPaletteIdentity {
    let key = ArtworkKey(
      source: image, itemID: Self.itemID, variant: .highFidelity(pixelWidth: 760),
      revision: ArtworkRevision(revision))
    return CoverPaletteIdentity(
      drawing: key, showSource: try showImage(), isProvisional: isProvisional)
  }

  private static func service() -> CoverPaletteService {
    CoverPaletteService(
      extraction: CoverPaletteService.Extraction(samples: { data in
        data.first == firstImageByte ? samplesA : samplesB
      }))
  }

  private static func request(
    _ identity: CoverPaletteIdentity, byte: UInt8, in service: CoverPaletteService
  ) async {
    _ = await service.request([
      CoverPaletteRequest(
        identity: identity,
        bytes: CoverPaletteService.CoverBytes(cached: { Data([byte]) }, awaitArrival: {}))
    ])
  }

  private static func resolve(
    _ latch: AmbientCanvasLatch, identity: CoverPaletteIdentity,
    in service: CoverPaletteService
  ) -> AmbientCanvas {
    latch.resolve(
      itemID: ExpandedPlayerView.canvasLatchKey(itemID: Self.itemID, identity: identity),
      palette: ExpandedPlayerView.canvasPalette(for: identity, in: service),
      appearance: .dark)
  }
}
