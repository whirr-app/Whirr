import SwiftUI

/// Spacing scale for DesignSystem layouts. Call sites reference these tokens instead of raw point
/// values so tuning is a single edit.
public enum WhirrSpacing {
  public static let xxSmall: CGFloat = 4
  public static let xSmall: CGFloat = 8
  public static let small: CGFloat = 12
  public static let medium: CGFloat = 16
  public static let large: CGFloat = 24
  public static let xLarge: CGFloat = 32
}

/// Layout constants that aren't part of the spacing scale.
public enum WhirrMetric {
  /// Apple HIG minimum hit target. Every tappable control must be at least this size.
  public static let minimumTouchTarget: CGFloat = 44
}
