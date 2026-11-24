import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

extension ExpandedPlayerView {
  /// Hold entry artwork evidence while app appearance and contrast select its precomputed variant.
  /// The palette lookup is lazy and runs once per committed cover, never on playhead ticks. The
  /// latch key names the drawn image rather than the item: an advance onto another episode of the
  /// same show can draw a different image, so it must re-select even though `itemID` is unchanged.
  var ambientCanvas: AmbientCanvas {
    let identity = paletteIdentity
    return canvasLatch.resolve(
      itemID: Self.canvasLatchKey(itemID: itemID, identity: identity),
      palette: Self.canvasPalette(for: identity, in: paletteService),
      appearance: effectiveAppColorScheme,
      increasedContrast: colorSchemeContrast == .increased)
  }

  /// The page's ink. The artwork lends the controls no colour, so the transport's focal disc marks
  /// emphasis with weight rather than hue.
  var accent: Color { ambientCanvas.accent }

  /// The canvas resolves timeline opacity once; this leaf only selects the stored regular or
  /// scrubbing value as its local gesture state changes.
  var timelineReadoutStyle: CoverAmbientPalette.TimelineReadoutStyle {
    ambientCanvas.timelineReadoutStyle
  }
}
