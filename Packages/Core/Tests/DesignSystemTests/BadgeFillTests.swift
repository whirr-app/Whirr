import SwiftUI
import Testing

@testable import DesignSystem

@Suite("Badge fill")
struct BadgeFillTests {

  @Test("the fill follows the colour scheme, light on light and dark on dark")
  func toneFollowsScheme() {
    let light = BadgeFill.decide(
      colorScheme: .light, reduceTransparency: false, increasedContrast: false)
    let dark = BadgeFill.decide(
      colorScheme: .dark, reduceTransparency: false, increasedContrast: false)
    #expect(light.white > 0.5)
    #expect(dark.white < 0.5)
  }

  @Test(
    "the default fill is see-through, so the artwork still shows behind it",
    arguments: [ColorScheme.light, .dark])
  func defaultIsTranslucent(scheme: ColorScheme) {
    let fill = BadgeFill.decide(
      colorScheme: scheme, reduceTransparency: false, increasedContrast: false)
    #expect(fill.opacity > 0.5)
    #expect(fill.opacity < 1)
  }

  @Test("Increase Contrast makes the fill more opaque", arguments: [ColorScheme.light, .dark])
  func increasedContrastStrengthens(scheme: ColorScheme) {
    let normal = BadgeFill.decide(
      colorScheme: scheme, reduceTransparency: false, increasedContrast: false)
    let strengthened = BadgeFill.decide(
      colorScheme: scheme, reduceTransparency: false, increasedContrast: true)
    #expect(strengthened.opacity > normal.opacity)
    #expect(strengthened.white == normal.white)
  }

  @Test(
    "Reduce Transparency makes the fill opaque, with or without Increase Contrast",
    arguments: [ColorScheme.light, .dark], [false, true])
  func reduceTransparencyIsOpaque(scheme: ColorScheme, increasedContrast: Bool) {
    let fill = BadgeFill.decide(
      colorScheme: scheme, reduceTransparency: true, increasedContrast: increasedContrast)
    #expect(fill.opacity == 1)
  }
}
