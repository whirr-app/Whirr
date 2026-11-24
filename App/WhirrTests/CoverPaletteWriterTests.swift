import ABSApi
import DesignSystem
import Foundation
import Persistence
import TestSupport
import Testing

@testable import Whirr

/// Pins the rules every palette writer shares, so the surfaces cannot drift onto rules of their
/// own.
@MainActor
@Suite struct CoverPaletteWriterTests {
  private static let scope = ArtworkAccountScope("https://writer.example.test#account=1")
  private static let revision = ArtworkRevision("rev-1")

  private static func key(_ variant: ArtworkVariant) -> ArtworkKey {
    ArtworkKey(accountScope: scope, itemID: "item", variant: variant, revision: revision)
  }

  private static var identity: String { CoverPaletteWriter.recordIdentity(for: key(.homeCard(pixelWidth: 280))) }

  private static let palette = CoverAmbientPalette.palette(from: EditorialWashTestSamples.value)

  @Test("A row answers only for its own cover, and only with the page evidence")
  func aRowAnswersOnlyForItsCoverWithEvidence() {
    let complete = CoverPaletteWriter.record(
      itemID: "item", identity: Self.identity, palette: Self.palette)
    let accentOnly = CoverPaletteRecord(
      itemId: "item", artworkKey: Self.identity, accentHue: 0.1, accentSaturation: 0.5,
      accentBrightness: 0.5, extractedAt: Date())

    #expect(CoverPaletteWriter.answers(complete, for: Self.identity))
    #expect(!CoverPaletteWriter.answers(complete, for: "another|cover"))
    #expect(!CoverPaletteWriter.answers(accentOnly, for: Self.identity))
    #expect(!CoverPaletteWriter.answers(nil, for: Self.identity))
  }

  @Test("The saved row carries the accent and the page evidence of the palette")
  func theSavedRowCarriesAccentAndEvidence() {
    let record = CoverPaletteWriter.record(
      itemID: "item", identity: Self.identity, palette: Self.palette)
    let evidence = Self.palette.ambientAppearance.evidence

    #expect(record.itemId == "item")
    #expect(record.artworkKey == Self.identity)
    #expect(record.accentHue == Self.palette.rawAccentHSB?.hue)
    #expect(record.clusterWeight == evidence.clusterWeight)
    #expect(record.averageRed == evidence.average.red)
    #expect(record.carriesPageEvidence)
  }

  @Test("Only a visible request on a cover that stands in for the card may wait for its fetch")
  func onlyAVisibleStandInMayJoinItsFetch() {
    let thumbnail = Self.key(.libraryThumbnail(pixelWidth: 132))
    let hero = Self.key(.highFidelity(pixelWidth: 4_096))

    #expect(CoverPaletteWriter.mayJoinDisplayFetch(hero, requestClass: .visible))
    #expect(!CoverPaletteWriter.mayJoinDisplayFetch(hero, requestClass: .background))
    #expect(!CoverPaletteWriter.mayJoinDisplayFetch(thumbnail, requestClass: .visible))
  }

  @Test("Cached source bytes are the card's, else a stand-in's, never a thumbnail's")
  func cachedSourceBytesFollowThePaletteSource() async {
    let thumbnail = Self.key(.libraryThumbnail(pixelWidth: 132))
    let hero = Self.key(.highFidelity(pixelWidth: 4_096))
    let card = CoverPaletteSource.cardKey(for: hero)
    let onDisk: [ArtworkKey: Data] = [thumbnail: Data([1]), hero: Data([3])]

    #expect(await CoverPaletteWriter.cachedSourceBytes(displayed: thumbnail) { onDisk[$0] } == nil)
    #expect(await CoverPaletteWriter.cachedSourceBytes(displayed: hero) { onDisk[$0] } == Data([3]))
    let withCard = onDisk.merging([card: Data([2])]) { $1 }
    #expect(
      await CoverPaletteWriter.cachedSourceBytes(displayed: thumbnail) { withCard[$0] } == Data([2]))
    #expect(await CoverPaletteWriter.cachedSourceBytes(displayed: hero) { withCard[$0] } == Data([2]))
  }

  @Test("A visible extraction goes ahead of background ones already waiting")
  func visibleExtractionGoesAheadOfWaitingBackgroundOnes() async {
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    let order = WriterOrder()
    try? await admission.acquire(priority: .visible)

    let background = Task {
      _ = await CoverPaletteWriter.samples(
        from: Data([1]), requestClass: .background, admission: admission
      ) { _ in
        await order.append("background")
        return nil
      }
    }
    await Self.waitForQueued(admission, count: 1)
    let visible = Task {
      _ = await CoverPaletteWriter.samples(
        from: Data([1]), requestClass: .visible, admission: admission
      ) { _ in
        await order.append("visible")
        return nil
      }
    }
    await Self.waitForQueued(admission, count: 2)
    await admission.release(priority: .visible)
    await background.value
    await visible.value

    #expect(await order.values == ["visible", "background"])
  }

  private static func waitForQueued(_ admission: CoverDecodeAdmission, count: Int) async {
    _ = await awaitCondition("queued", until: { await admission.queuedCount >= count })
  }
}

private actor WriterOrder {
  private(set) var values: [String] = []

  func append(_ value: String) { values.append(value) }
}
