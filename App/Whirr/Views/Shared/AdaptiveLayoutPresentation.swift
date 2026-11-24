import Foundation

/// Shared width ceilings for prose and primary controls. Callers supply the width of their local
/// container so split-view panes and nested sheets do not inherit a screen-wide measurement.
nonisolated enum AdaptiveLayoutPresentation {
  static let readingMeasure: CGFloat = 640
  static let primaryControlMaxWidth: CGFloat = 480
  static let accessibilityPrimaryControlMaxWidth: CGFloat = 640

  static func readableWidth(forAvailableWidth width: CGFloat) -> CGFloat {
    cappedWidth(width, at: readingMeasure)
  }

  static func primaryControlWidth(
    forAvailableWidth width: CGFloat,
    isAccessibilitySize: Bool
  ) -> CGFloat {
    cappedWidth(
      width,
      at: isAccessibilitySize
        ? accessibilityPrimaryControlMaxWidth
        : primaryControlMaxWidth)
  }

  private static func cappedWidth(_ width: CGFloat, at ceiling: CGFloat) -> CGFloat {
    guard width.isFinite, width > 0 else { return 0 }
    return min(width, ceiling)
  }
}
