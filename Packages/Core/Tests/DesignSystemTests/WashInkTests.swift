import SwiftUI
import Testing

@testable import DesignSystem

/// The near-white text set drawn on a dark wash. See `WashInk`.
@Suite("Wash ink")
struct WashInkTests {
  private static let hueCircle = (0..<72).map {
    CoverWash.from(hue: Double($0) / 72, saturation: 0.8, brightness: 0.7)
  }

  @Test("the dark ink clears AA on every dark card")
  func darkInkIsLegibleOnCards() {
    for wash in Self.hueCircle + [.neutral] {
      let card = wash.dark.rgbColor

      #expect(contrastRatio(WhirrRGBColor(1, 1, 1), card) >= 7)
      for increasedContrast in [false, true] {
        let secondary = WashInk.darkSecondary(on: card, increasedContrast: increasedContrast)
        #expect(contrastRatio(secondary, card) >= 4.5)
      }
      if let tint = wash.darkTint {
        #expect(contrastRatio(tint.rgbColor, card) >= 4.5)
      }
    }
  }

  /// The show page's header is drawn on the page wash.
  @Test("the dark secondary ink clears AA on every page wash")
  func darkSecondaryIsLegibleOnPageWashes() {
    for wash in Self.hueCircle {
      let page = wash.darkPage.rgbColor
      for increasedContrast in [false, true] {
        let secondary = WashInk.darkSecondary(on: page, increasedContrast: increasedContrast)
        #expect(contrastRatio(secondary, page) >= 4.5)
      }
    }
  }

  /// Destructive labels sit on the neutral cards of the storage controls and on a downloaded
  /// show's tinted card, where system red falls as low as 3.3:1.
  @Test("the dark destructive ink clears AA on every dark card")
  func darkDestructiveIsLegible() {
    for wash in Self.hueCircle + [.neutral] {
      #expect(contrastRatio(WashInk.darkDestructiveRGB, wash.dark.rgbColor) >= 4.5)
    }
  }

  @Test("the tint is a pale form of the cover's own hue")
  func tintIsAPaleFormOfTheCoverHue() {
    for (step, wash) in Self.hueCircle.enumerated() {
      guard let tint = wash.darkTint else {
        Issue.record("a hued wash carries a tint")
        continue
      }
      #expect(abs(tint.oklabLightness - 0.93) < 0.005)
      #expect(tint.oklabChroma <= 0.06 + 0.001)
      let hue = CoverWashValue(hue: Double(step) / 72, saturation: 1, brightness: 1)
      let drift = abs(tint.oklabHueDegrees - hue.oklabHueDegrees)
      #expect(min(drift, 360 - drift) < 1.5)
    }
    #expect(CoverWash.neutral.darkTint == nil)
  }

  @Test("the dark ink applies only on a wash in the dark appearance")
  func darkInkScope() {
    #expect(WashInk.drawsDarkInk(colorScheme: .dark, isOnWash: true))
    #expect(!WashInk.drawsDarkInk(colorScheme: .light, isOnWash: true))
    #expect(!WashInk.drawsDarkInk(colorScheme: .dark, isOnWash: false))
  }
}
