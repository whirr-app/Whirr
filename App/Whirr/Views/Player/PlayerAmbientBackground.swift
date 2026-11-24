import DesignSystem
import SwiftUI

/// The player's single ambient canvas: the artwork-derived colour, flat.
///
/// Flat: lightness is clamped into a band where the ink clears AA at the dimmest rung, so a
/// gradient would buy nothing and cost the artwork's colour. Depth comes from the cover's shadow.
/// Ignoring the safe area reaches the screen edges only because the page is presented through the
/// UIKit-owned full-screen transition; inside a sheet it stops at the card.
struct PlayerAmbientBackground: View {
  let background: Color
  /// `AmbientCanvasLatch.adoptionGeneration`. The crossfade is keyed to this rather than to
  /// `background` so it runs only for a palette that arrived late: an advance onto an item whose
  /// palette was already derived changes colour with its cover, on one frame.
  var adoptionGeneration: Int = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    background
      .ignoresSafeArea()
      .animation(
        PlayerMotion.ambientAdoptionAnimation(reduceMotion: reduceMotion),
        value: adoptionGeneration)
  }
}
