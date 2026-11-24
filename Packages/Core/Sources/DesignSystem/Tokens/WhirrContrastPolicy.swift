import SwiftUI

/// What Increase Contrast changes about a surface. Separated from the colors themselves so the
/// decision is assertable without a renderer, the same way `GlassEffectPolicy` separates the
/// Reduce Transparency decision from `GlassContainer`.
public struct WhirrContrastDecision: Sendable, Equatable {
  /// Whether artwork-derived washes still paint. Under Increase Contrast they do not: a wash is
  /// decoration sampled from a cover, and the setting exists precisely to stop decoration
  /// competing with the text on top of it.
  public let usesArtworkWash: Bool
  /// Whether the two custom-valued tokens resolve to their strengthened variants.
  public let usesStrengthenedInk: Bool

  public init(usesArtworkWash: Bool, usesStrengthenedInk: Bool) {
    self.usesArtworkWash = usesArtworkWash
    self.usesStrengthenedInk = usesStrengthenedInk
  }
}

/// The app's Increase Contrast policy.
///
/// Most `WhirrColorToken` cases are system colors the platform already strengthens for this
/// setting. Two (`editorialBackground` and `brandInk`) and the cover washes carry literal values
/// and opt out unless this policy tells them.
public enum WhirrContrastPolicy {
  public static func decide(prefersIncreasedContrast: Bool) -> WhirrContrastDecision {
    WhirrContrastDecision(
      usesArtworkWash: prefersIncreasedContrast == false,
      usesStrengthenedInk: prefersIncreasedContrast)
  }
}

#if canImport(UIKit)
  import UIKit

  extension UITraitCollection {
    /// One place to read the trait, so a call site cannot accidentally check
    /// `.unspecified` as though it meant high contrast.
    var prefersIncreasedContrast: Bool { accessibilityContrast == .high }
  }
#endif
