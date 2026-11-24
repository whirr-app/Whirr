import DesignSystem
import SwiftUI
import Testing

@testable import Whirr

@Suite struct AmbientAppAppearanceRegressionTests {
  @Test("Light appearance keeps dark and colourful artwork on a pale canvas")
  func lightAppearanceOwnsCanvasAndInk() {
    for source in [
      CoverRGBA(red: 0.05, green: 0.05, blue: 0.05),
      CoverRGBA(red: 0.55, green: 0.01, blue: 0.01),
      CoverRGBA(red: 0.1, green: 0.2, blue: 0.6),
    ] {
      let palette = CoverAmbientPalette.palette(
        from: CoverPaletteSamples(average: source, dominant: [source]))
      for increasedContrast in [false, true] {
        let canvas = palette.ambientAppearance.canvas(
          for: .light, increasedContrast: increasedContrast)
        #expect(canvas.mode == .light)
        #expect(canvas.inkRGB == WhirrRGBColor(0, 0, 0))
      }
    }
  }

  @Test("Dark appearance keeps bright artwork on a deep canvas")
  func darkAppearanceOwnsCanvasAndInk() {
    let source = CoverRGBA(red: 0.95, green: 0.85, blue: 0.2)
    let palette = CoverAmbientPalette.palette(
      from: CoverPaletteSamples(average: source, dominant: [source]))
    for increasedContrast in [false, true] {
      let canvas = palette.ambientAppearance.canvas(
        for: .dark, increasedContrast: increasedContrast)
      #expect(canvas.mode == .dark)
      #expect(canvas.inkRGB == WhirrRGBColor(1, 1, 1))
    }
  }
}
