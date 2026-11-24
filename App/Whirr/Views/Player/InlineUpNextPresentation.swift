import CoreGraphics
import DesignSystem

/// Where Up Next appears and how the page makes room for it, as pure functions. On a portrait
/// phone the expanded player changes mode in place: the cover shrinks to a header thumbnail and the
/// queue takes the freed upper region. Every other composition keeps the sheet.
nonisolated enum InlineUpNextPresentation {
  nonisolated enum Placement: Equatable, Sendable {
    case inline
    case sheet
  }

  /// Inline needs the stacked compact page's tall upper region. Side by side has no such region,
  /// a regular width has room for the sheet beside the page's subject, and accessibility text
  /// sizes already overflow the upper region without a list in it.
  static func placement(
    widthClass: ExpandedPlayerLayoutPresentation.WidthClass,
    isCompactHeight: Bool,
    isAccessibilitySize: Bool
  ) -> Placement {
    widthClass == .compact && isCompactHeight == false && isAccessibilitySize == false
      ? .inline : .sheet
  }

  /// The page keeps one flag. Narrowing it by placement means a rotation while the queue is open
  /// hands it from one presentation to the other rather than showing both or neither.
  static func isSheetPresented(isShowingUpNext: Bool, placement: Placement) -> Bool {
    isShowingUpNext && placement == .sheet
  }

  static func isInlineShown(isShowingUpNext: Bool, placement: Placement) -> Bool {
    isShowingUpNext && placement == .inline
  }

  /// Inline, the quick action is the queue's only close control, so it toggles.
  static func toggle(_ isShowingUpNext: inout Bool) {
    isShowingUpNext.toggle()
  }

  /// The sheet covers the page, so the page holds its committed identity until the sheet has gone.
  /// Inline, the page is visible and live and must follow playback as the queue advances.
  static func freezesCommittedIdentity(_ placement: Placement) -> Bool {
    placement == .sheet
  }

  // MARK: - Header geometry

  nonisolated struct Header: Equatable, Sendable {
    let artworkSize: CGFloat
    let artworkToTitleSpacing: CGFloat
    let verticalPadding: CGFloat

    var height: CGFloat { artworkSize + verticalPadding * 2 }
  }

  static let header = Header(
    artworkSize: 64,
    artworkToTitleSpacing: WhirrSpacing.medium,
    verticalPadding: WhirrSpacing.small)

  /// The height over which the queue's last rows fade out above the scrubber.
  static let queueBottomFadeHeight: CGFloat = 28

  /// The full page's cover radius, scaled down for a thumbnail so its corners keep the same
  /// proportion instead of rounding the thumbnail into a blob.
  static func artworkCornerRadius(coverSize: CGFloat) -> CGFloat {
    min(pageArtworkCornerRadius, max(6, coverSize * 0.14))
  }

  static let pageArtworkCornerRadius: CGFloat = 18

  static let hideLabel = "Hide Up Next"
  static let hideHint = "Returns to the cover and title."
}
