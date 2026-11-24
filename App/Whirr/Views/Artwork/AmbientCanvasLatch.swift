import SwiftUI

/// Lazily commits the artwork evidence for one displayed item/presentation. Its `itemID` is an
/// opaque key: the expanded player keys it by the drawn image's row, because one item's episodes
/// can each draw a different cover.
///
/// The selected palette is memoized, so rendering follows appearance and Increase Contrast while
/// late extraction or cache eviction cannot recolour a settled page. A `nil` selection is memoized
/// too, except when a live page's item changes underneath it: the expanded player keeps one view
/// identity across queue advances, and the first body after an auto-advance runs before the new
/// item's extraction, so that `nil` is provisional and re-reads until a palette arrives. A
/// latch's first-ever selection is never provisional, which keeps a pushed detail screen stable.
///
/// `adoptsLatePaletteOnArrival` makes the first selection provisional too. Item detail sets it: a
/// new item has no palette record and the tap's extraction can't finish inside the push's
/// preparation deadline. A palette present on the first frame is final.
///
/// Not observable: resolving memoizes an input during body evaluation, like `DeferredModel`.
@MainActor
final class AmbientCanvasLatch {
  private var selectedItemID: String?
  private var selectedPalette: CoverPalette?
  private var isProvisional = false
  private var adoptions = 0
  private let adoptsLatePaletteOnArrival: Bool

  init(adoptsLatePaletteOnArrival: Bool = false) {
    self.adoptsLatePaletteOnArrival = adoptsLatePaletteOnArrival
  }

  func resolve(
    itemID: String,
    palette: @autoclosure () -> CoverPalette?,
    appearance: ColorScheme,
    increasedContrast: Bool = false
  ) -> AmbientCanvas {
    if selectedItemID != itemID {
      // An item change under a latch that has already selected for something is the auto-advance
      // case; a first selection is a page arriving.
      let isItemChange = selectedItemID != nil
      selectedItemID = itemID
      selectedPalette = palette()
      isProvisional = (isItemChange || adoptsLatePaletteOnArrival) && selectedPalette == nil
    } else if isProvisional, let arrived = palette() {
      selectedPalette = arrived
      isProvisional = false
      adoptions += 1
    }
    return selectedPalette?.ambientAppearance.canvas(
      for: appearance, increasedContrast: increasedContrast)
      ?? CoverAmbientPalette.fallbackCanvas(
        for: appearance, increasedContrast: increasedContrast)
  }

  var itemID: String? { selectedItemID }
  var palette: CoverPalette? { selectedPalette }

  /// Increments each time a provisional selection adopts a palette that arrived late, and at no
  /// other time. The page animates its canvas on changes to this value rather than on the colour
  /// itself, so an advance onto an already-derived item changes colour with its cover on the first
  /// frame instead of fading in behind it. `CoverImageView.completionAnimation` draws the same
  /// distinction between a prepared hit and a cold completion.
  var adoptionGeneration: Int { adoptions }
}
