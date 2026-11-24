import DesignSystem
import SwiftUI
import Testing
import UIKit

/// Only the system-backed `WhirrColorToken` cases (six of eight) adapt to Increase Contrast on
/// their own. `editorialBackground`, `brandInk` and the cover washes are literal and stay as they
/// are.
///
/// `DesignSystemTests` asserts the policy and palette arithmetic; this asserts that a resolved
/// dynamic colour follows the trait, which needs a real `UITraitCollection`.
@Suite("Increase Contrast resolution")
struct WhirrIncreasedContrastTests {

  @Test(
    "the literal-valued tokens resolve to their strengthened variant under Increase Contrast",
    arguments: [WhirrColorToken.editorialBackground, .brandInk])
  func literalTokensFollowTheContrastTrait(token: WhirrColorToken) {
    for style in [UIUserInterfaceStyle.light, .dark] {
      let standard = token.resolved(style: style, contrast: .normal)
      let increased = token.resolved(style: style, contrast: .high)
      #expect(
        standard != increased,
        "\(token.rawValue) resolves identically with and without Increase Contrast in \(style)")
    }
  }

  @Test("the strengthened pair really does widen on screen, in both appearances")
  func resolvedPairWidensUnderIncreasedContrast() {
    // The palette test in Core proves the literals are further apart. This proves the colours the
    // system hands back, which is the part a broken trait branch would silently lose.
    for style in [UIUserInterfaceStyle.light, .dark] {
      let standard = contrastRatio(
        WhirrColorToken.brandInk.resolved(style: style, contrast: .normal),
        WhirrColorToken.editorialBackground.resolved(style: style, contrast: .normal))
      let increased = contrastRatio(
        WhirrColorToken.brandInk.resolved(style: style, contrast: .high),
        WhirrColorToken.editorialBackground.resolved(style: style, contrast: .high))
      #expect(increased > standard, "Increase Contrast did not widen the pair in \(style)")
      #expect(increased >= 7, "the strengthened pair misses WCAG AAA in \(style)")
    }
  }

  @Test("an artwork wash stops tinting under Increase Contrast and falls back to neutral")
  func artworkWashesNeutralizeUnderIncreasedContrast() {
    // A saturated cover, well past `from`'s saturation floor, so the wash is visibly tinted.
    let tinted = CoverWash.from(hue: 0.58, saturation: 0.62, brightness: 0.55)
    #expect(tinted.cardColor != CoverWash.neutral.cardColor, "the fixture wash is not tinted")

    for style in [UIUserInterfaceStyle.light, .dark] {
      #expect(
        tinted.cardColor.resolved(style: style, contrast: .high)
          == CoverWash.neutral.cardColor.resolved(style: style, contrast: .high),
        "the card wash still tints under Increase Contrast in \(style)")
      #expect(
        tinted.pageColor.resolved(style: style, contrast: .high)
          == CoverWash.neutral.pageColor.resolved(style: style, contrast: .high),
        "the page wash still tints under Increase Contrast in \(style)")
      #expect(
        tinted.cardColor.resolved(style: style, contrast: .normal)
          != CoverWash.neutral.cardColor.resolved(style: style, contrast: .normal),
        "the wash stopped tinting even without Increase Contrast in \(style)")
    }
  }

  @Test("the progress accent survives Increase Contrast")
  func accentIsNotSuppressed() throws {
    // Increase Contrast must not remove a status mark. The accent carries progress, so unlike the
    // background regions it is left alone.
    let tinted = CoverWash.from(hue: 0.58, saturation: 0.62, brightness: 0.55)
    let accent = try #require(tinted.accentColor)
    #expect(
      accent.resolved(style: .dark, contrast: .high)
        == accent.resolved(style: .dark, contrast: .normal))
  }
}

extension WhirrColorToken {
  fileprivate func resolved(
    style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast
  ) -> WhirrRGBColor {
    color.resolved(style: style, contrast: contrast)
  }
}

extension Color {
  fileprivate func resolved(
    style: UIUserInterfaceStyle, contrast: UIAccessibilityContrast
  ) -> WhirrRGBColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    let traits = UITraitCollection { mutable in
      mutable.userInterfaceStyle = style
      mutable.accessibilityContrast = contrast
    }
    UIColor(self)
      .resolvedColor(with: traits)
      .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return WhirrRGBColor(Double(red), Double(green), Double(blue))
  }
}
