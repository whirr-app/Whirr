import DesignSystem
import SwiftUI
import Testing
import UIKit

/// The light/dark proof for `WhirrColorToken`. Lives here, not in `DesignSystemTests`, because
/// resolving a dynamic colour needs a real trait collection (`Color.resolve(in:)` blocks forever on
/// the macOS host). Each token must resolve to a light and a dark value; a hardcoded dark literal
/// would render light mode as a dark screen.
@Suite("WhirrColorToken appearance adaptivity")
struct WhirrColorTokenAppearanceTests {

  @Test("every color token resolves differently in light and dark", arguments: WhirrColorToken.allCases)
  func tokensResolveDifferentlyPerAppearance(token: WhirrColorToken) {
    #expect(
      token.resolved(.light) != token.resolved(.dark),
      "\(token.rawValue) resolves identically in both appearances - it is pinned to one scheme")
  }

  @Test(
    "surface tokens are light in the light appearance and dark in the dark one",
    arguments: [WhirrColorToken.surfacePrimary, .surfaceSecondary])
  func surfaceTokensTrackTheirAppearance(token: WhirrColorToken) {
    #expect(token.resolved(.light).isCloserToWhite)
    #expect(!token.resolved(.dark).isCloserToWhite)
  }

  @Test(
    "text tokens contrast against the appearance they sit on",
    arguments: [WhirrColorToken.textPrimary, .textSecondary])
  func textTokensContrastAgainstTheirAppearance(token: WhirrColorToken) {
    #expect(!token.resolved(.light).isCloserToWhite)
    #expect(token.resolved(.dark).isCloserToWhite)
  }
}

extension WhirrColorToken {
  fileprivate func resolved(_ style: UIUserInterfaceStyle) -> WhirrRGBColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(color)
      .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
      .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return WhirrRGBColor(Double(red), Double(green), Double(blue))
  }
}

extension WhirrRGBColor {
  /// Uses the shared WCAG contrast math rather than a raw component threshold, so "light" means
  /// perceptually light rather than numerically large in one channel.
  fileprivate var isCloserToWhite: Bool {
    contrastRatio(self, WhirrRGBColor(1, 1, 1)) < contrastRatio(self, WhirrRGBColor(0, 0, 0))
  }
}
