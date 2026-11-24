import DesignSystem
import SwiftUI
import Testing

@testable import Whirr

@MainActor
@Suite struct AmbientCanvasLatchTests {
  private static let palette = CoverAmbientPalette.palette(
    from: CoverPaletteSamples(
      average: CoverRGBA(red: 0.82, green: 0.68, blue: 0.45),
      dominant: [CoverRGBA(red: 0.82, green: 0.68, blue: 0.45, weight: 0.8)]))

  @Test func nilEntryIsStableAfterLatePaletteArrivalAndAppearanceChange() {
    let latch = AmbientCanvasLatch()
    let initial = latch.resolve(itemID: "a", palette: nil, appearance: .dark)
    let late = latch.resolve(itemID: "a", palette: Self.palette, appearance: .light)
    #expect(initial == CoverAmbientPalette.fallbackCanvas(for: .dark))
    #expect(late == CoverAmbientPalette.fallbackCanvas(for: .light))
  }

  @Test func selectedPaletteSurvivesCacheEvictionAndAppearanceChange() {
    let latch = AmbientCanvasLatch()
    let dark = latch.resolve(itemID: "a", palette: Self.palette, appearance: .dark)
    let light = latch.resolve(itemID: "a", palette: nil, appearance: .light)
    #expect(dark.mode == .dark)
    #expect(light.mode == .light)
    #expect(latch.palette == Self.palette)
  }

  @Test func anItemChangeAdoptsAPaletteThatArrivesAfterTheFirstResolve() {
    let latch = AmbientCanvasLatch()
    _ = latch.resolve(itemID: "a", palette: Self.palette, appearance: .dark)
    let advanced = latch.resolve(itemID: "b", palette: nil, appearance: .dark)
    #expect(advanced == CoverAmbientPalette.fallbackCanvas(for: .dark))
    #expect(latch.adoptionGeneration == 0)
    let adopted = latch.resolve(itemID: "b", palette: Self.palette, appearance: .dark)
    #expect(adopted == Self.palette.ambientAppearance.canvas(for: .dark))
    #expect(latch.adoptionGeneration == 1)
  }

  @Test func anAdoptedSelectionIsFinalAndIsNeverReadAgain() {
    let latch = AmbientCanvasLatch()
    _ = latch.resolve(itemID: "a", palette: Self.palette, appearance: .dark)
    _ = latch.resolve(itemID: "b", palette: nil, appearance: .dark)
    _ = latch.resolve(itemID: "b", palette: Self.palette, appearance: .dark)
    var reads = 0
    func readPalette() -> CoverPalette? {
      reads += 1
      return nil
    }
    let held = latch.resolve(itemID: "b", palette: readPalette(), appearance: .dark)
    #expect(reads == 0)
    #expect(held == Self.palette.ambientAppearance.canvas(for: .dark))
    #expect(latch.adoptionGeneration == 1)
  }

  @Test func anItemChangeWithACachedPaletteIsNotAnAdoption() {
    let latch = AmbientCanvasLatch()
    _ = latch.resolve(itemID: "a", palette: nil, appearance: .dark)
    let advanced = latch.resolve(itemID: "b", palette: Self.palette, appearance: .dark)
    #expect(advanced == Self.palette.ambientAppearance.canvas(for: .dark))
    #expect(latch.adoptionGeneration == 0)
  }

  @Test func aProvisionalSelectionIsAbandonedByAFurtherItemChange() {
    let latch = AmbientCanvasLatch()
    _ = latch.resolve(itemID: "a", palette: Self.palette, appearance: .dark)
    _ = latch.resolve(itemID: "b", palette: nil, appearance: .dark)
    let third = latch.resolve(itemID: "c", palette: nil, appearance: .dark)
    #expect(third == CoverAmbientPalette.fallbackCanvas(for: .dark))
    #expect(latch.itemID == "c")
    #expect(latch.palette == nil)
    // "b"'s palette arriving now belongs to an item the page has already left.
    let stillNeutral = latch.resolve(itemID: "c", palette: nil, appearance: .dark)
    #expect(stillNeutral == CoverAmbientPalette.fallbackCanvas(for: .dark))
    #expect(latch.adoptionGeneration == 0)
  }

  @Test func appearanceAndContrastChangesDoNotCommitAProvisionalSelection() {
    let latch = AmbientCanvasLatch()
    _ = latch.resolve(itemID: "a", palette: Self.palette, appearance: .dark)
    _ = latch.resolve(itemID: "b", palette: nil, appearance: .dark)
    let light = latch.resolve(itemID: "b", palette: nil, appearance: .light)
    let strengthened = latch.resolve(
      itemID: "b", palette: nil, appearance: .light, increasedContrast: true)
    #expect(light == CoverAmbientPalette.fallbackCanvas(for: .light))
    #expect(
      strengthened == CoverAmbientPalette.fallbackCanvas(for: .light, increasedContrast: true))
    #expect(latch.adoptionGeneration == 0)
  }

  @Test func newItemWithNilPaletteNeverInheritsPreviousEvidence() {
    let latch = AmbientCanvasLatch()
    _ = latch.resolve(itemID: "a", palette: Self.palette, appearance: .light)
    let next = latch.resolve(itemID: "b", palette: nil, appearance: .light)
    #expect(next == CoverAmbientPalette.fallbackCanvas(for: .light))
    #expect(latch.itemID == "b")
    #expect(latch.palette == nil)
  }

  @Test func paletteProviderIsReadOncePerItem() {
    let latch = AmbientCanvasLatch()
    var reads = 0
    func readPalette() -> CoverPalette? {
      reads += 1
      return Self.palette
    }
    _ = latch.resolve(itemID: "a", palette: readPalette(), appearance: .dark)
    _ = latch.resolve(itemID: "a", palette: readPalette(), appearance: .light)
    #expect(reads == 1)
    _ = latch.resolve(itemID: "b", palette: readPalette(), appearance: .light)
    #expect(reads == 2)
  }
  @Test func contrastChangesResolveTheOriginalSelection() {
    for entry in [Self.palette, nil] {
      let latch = AmbientCanvasLatch()
      _ = latch.resolve(itemID: "a", palette: entry, appearance: .light)
      let strengthened = latch.resolve(
        itemID: "a", palette: nil, appearance: .light, increasedContrast: true)
      let expected =
        entry?.ambientAppearance.canvas(for: .light, increasedContrast: true)
        ?? CoverAmbientPalette.fallbackCanvas(for: .light, increasedContrast: true)
      #expect(strengthened == expected)
    }
  }

  @Test func aPageThatAdoptsOnArrivalTakesAPaletteThatArrivesAfterItsFirstResolve() {
    let latch = AmbientCanvasLatch(adoptsLatePaletteOnArrival: true)
    let initial = latch.resolve(itemID: "a", palette: nil, appearance: .dark)
    #expect(initial == CoverAmbientPalette.fallbackCanvas(for: .dark))
    #expect(latch.adoptionGeneration == 0)
    let adopted = latch.resolve(itemID: "a", palette: Self.palette, appearance: .dark)
    #expect(adopted == Self.palette.ambientAppearance.canvas(for: .dark))
    #expect(latch.adoptionGeneration == 1)
  }

  /// The player opens on whatever its store holds. On a cold launch that can be nothing, with the
  /// row arriving moments later; a final first frame left the play button white for the visit.
  @Test func theExpandedPlayerAdoptsAPaletteThatArrivesAfterItOpens() {
    let latch = ExpandedPlayerView.makeCanvasLatch()
    _ = latch.resolve(itemID: "a", palette: nil, appearance: .dark)
    let adopted = latch.resolve(itemID: "a", palette: Self.palette, appearance: .dark)
    #expect(adopted == Self.palette.ambientAppearance.canvas(for: .dark))
  }

  @Test func aPageThatAdoptsOnArrivalStillHoldsAPaletteItHadOnItsFirstFrame() {
    let latch = AmbientCanvasLatch(adoptsLatePaletteOnArrival: true)
    _ = latch.resolve(itemID: "a", palette: Self.palette, appearance: .dark)
    var reads = 0
    func readPalette() -> CoverPalette? {
      reads += 1
      return nil
    }
    let held = latch.resolve(itemID: "a", palette: readPalette(), appearance: .dark)
    #expect(reads == 0)
    #expect(held == Self.palette.ambientAppearance.canvas(for: .dark))
    #expect(latch.adoptionGeneration == 0)
  }

  @Test func aNewPresentationCanUseAPaletteThatArrivedDuringThePreviousVisit() {
    let firstVisit = AmbientCanvasLatch()
    _ = firstVisit.resolve(itemID: "a", palette: nil, appearance: .light)
    #expect(
      firstVisit.resolve(itemID: "a", palette: Self.palette, appearance: .light)
        == CoverAmbientPalette.fallbackCanvas(for: .light))
    let nextVisit = AmbientCanvasLatch()
    #expect(
      nextVisit.resolve(itemID: "a", palette: Self.palette, appearance: .light)
        == Self.palette.ambientAppearance.canvas(for: .light))
  }

}
