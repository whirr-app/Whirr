import SwiftUI

/// How the reader's system toolbars come and go. Pure so the contract is testable without a host
/// renderer, the same way `GlassEffectPolicy` and `GlassContainer.transitionAnimation` are.
public enum ReaderChromeMotion {
  /// Long enough to read as the controls getting out of the page's way, short enough that a reader
  /// tapping to turn a page is not kept waiting by it.
  public static let duration: Double = 0.28

  /// Reduce Motion suppresses the animation (ARCHITECTURE.md). A `nil` animation leaves the change
  /// instant rather than merely faster.
  public static func animation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .smooth(duration: duration)
  }
}
