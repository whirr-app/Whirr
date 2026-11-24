import DesignSystem
import Foundation
import SwiftUI

/// Pure presentation policy for the item-detail content surface. The scroll view supplies its
/// local measured width and Dynamic Type state; this type chooses the hero arrangement and the
/// width of the one control container that is allowed to be narrower than the page.
///
/// Hero arrangement is not a width decision: cover-beside-metadata on a regular-width iPad leaves
/// an L-shaped hole under the credits. Large screens cap prose and controls instead
/// (`readableWidth`, `actionWidth`).
nonisolated struct ItemDetailLayoutPresentation: Equatable, Sendable {
  nonisolated enum Hero: Equatable, Sendable {
    case promotedStack
    case stackedLeading
  }

  /// The narrowest real layout (a 320pt pane less page padding, with room to spare). A callback
  /// below it is a transient pass (restored snapshot, off-screen tab) and is treated as no
  /// measurement: honouring it would latch a squeezed `actionWidth` and reflow the capsule label.
  static let minimumMeasuredWidth: CGFloat = 200

  let hero: Hero
  /// Either a real measurement or `readingMeasure`. Never the caller's raw report, so every width
  /// derived below stays inside a pane the page could actually have been given.
  let availableWidth: CGFloat
  let readableWidth: CGFloat
  let actionWidth: CGFloat
  /// `nil` until the rendered hero reports its actual height. A missing measurement must not make
  /// the navigation title appear on the first frame of a freshly mounted page.
  let inlineTitleRevealOffset: CGFloat?

  static func resolve(
    horizontalSizeClass: UserInterfaceSizeClass?,
    isAccessibilitySize: Bool,
    availableWidth: CGFloat? = nil,
    measuredHeroHeight: CGFloat? = nil
  ) -> Self {
    let width = normalizedWidth(availableWidth)
    let measuredHeight = validHeroHeight(measuredHeroHeight)
    let hero = resolvedHero(for: horizontalSizeClass, isAccessibilitySize: isAccessibilitySize)

    return Self(
      hero: hero,
      availableWidth: width,
      readableWidth: AdaptiveLayoutPresentation.readableWidth(forAvailableWidth: width),
      actionWidth: actionWidth(
        forAvailableWidth: width, isAccessibilitySize: isAccessibilitySize),
      inlineTitleRevealOffset: measuredHeight.map {
        inlineTitleRevealOffset(forMeasuredHeroHeight: $0)
      })
  }

  /// Accessibility sizes keep the leading stack at every width; every ordinary size gets the
  /// promoted stack. The size class is unused today, kept so a future width policy needs no
  /// caller changes.
  static func hero(
    for horizontalSizeClass: UserInterfaceSizeClass?,
    isAccessibilitySize: Bool
  ) -> Hero {
    resolvedHero(for: horizontalSizeClass, isAccessibilitySize: isAccessibilitySize)
  }

  /// The action row is capped independently of prose. Its arrangement remains the responsibility
  /// of `ItemDetailActionRow`; this value only sizes that row's outer container.
  static func actionWidth(
    forAvailableWidth width: CGFloat,
    isAccessibilitySize: Bool
  ) -> CGFloat {
    AdaptiveLayoutPresentation.primaryControlWidth(
      forAvailableWidth: width, isAccessibilitySize: isAccessibilitySize)
  }

  /// Reveal after the measured hero has passed the navigation bar. The height is measured from the
  /// rendered composition, so a regular metadata column, a promoted stack, and a wrapped
  /// accessibility hero each get their actual threshold rather than one inferred from artwork.
  static func inlineTitleRevealOffset(forMeasuredHeroHeight height: CGFloat) -> CGFloat {
    validHeroHeight(height) ?? 0
  }

  func shouldRevealInlineTitle(at contentOffset: CGFloat) -> Bool {
    guard let inlineTitleRevealOffset, contentOffset.isFinite else { return false }
    return contentOffset > inlineTitleRevealOffset
  }

  private static func resolvedHero(
    for horizontalSizeClass: UserInterfaceSizeClass?,
    isAccessibilitySize: Bool
  ) -> Hero {
    _ = horizontalSizeClass
    return isAccessibilitySize ? .stackedLeading : .promotedStack
  }

  /// A measurement that is absent, unusable, or too narrow to be a pane falls back to the reading
  /// measure, the width the first frame is laid out at. One rule covers "not measured yet" and
  /// "measured during a pass that meant nothing".
  private static func normalizedWidth(_ width: CGFloat?) -> CGFloat {
    guard let width, width.isFinite, width >= minimumMeasuredWidth else {
      return AdaptiveLayoutPresentation.readingMeasure
    }
    return width
  }

  private static func validHeroHeight(_ height: CGFloat?) -> CGFloat? {
    guard let height, height.isFinite, height > 0 else { return nil }
    return height
  }
}
