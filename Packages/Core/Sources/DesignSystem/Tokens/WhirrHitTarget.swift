import SwiftUI

/// Geometry for the region a control should accept a tap in, which is not always the region it
/// draws in.
///
/// A label-only control (a byline, a show name, a text button) is as tall as its type.
/// `frame(minHeight:)` to `WhirrMetric.minimumTouchTarget` also inserts vertical space, and some
/// pairings are tight by design (the expanded player's byline is flush with the title above it).
/// This grows the region, not the layout, symmetrically on whichever axis falls short.
public enum WhirrHitTargetGeometry {
  /// The tappable region in the control's own coordinate space. An axis already at or past
  /// `minimum` is returned unchanged: this only ever grows a control, never crops one.
  public static func region(
    for size: CGSize, minimum: CGFloat = WhirrMetric.minimumTouchTarget
  ) -> CGRect {
    let width = max(size.width, minimum)
    let height = max(size.height, minimum)
    return CGRect(
      x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
  }
}

/// `WhirrHitTargetGeometry` as a `Shape`, so the region is derived from the rect SwiftUI proposes
/// rather than from a measurement the call site has to carry in its own state.
public struct WhirrHitTargetShape: Shape {
  public var minimum: CGFloat

  public init(minimum: CGFloat = WhirrMetric.minimumTouchTarget) {
    self.minimum = minimum
  }

  public func path(in rect: CGRect) -> Path {
    Path(
      WhirrHitTargetGeometry.region(for: rect.size, minimum: minimum)
        .offsetBy(dx: rect.minX, dy: rect.minY))
  }
}

extension View {
  /// Brings a control's touch target and its assistive-technology frame up to the HIG minimum
  /// without moving anything around it.
  ///
  /// Both kinds are named: `.interaction` is what a finger hits, `.accessibility` is the frame
  /// Switch Control, Voice Control and the Accessibility Inspector's Hit Region audit read. A
  /// `frame(minHeight:)` with no content shape satisfies neither (Save for Later reserved 44
  /// points and still measured 23.2).
  public func whirrMinimumHitTarget(_ minimum: CGFloat = WhirrMetric.minimumTouchTarget)
    -> some View
  {
    contentShape([.interaction, .accessibility], WhirrHitTargetShape(minimum: minimum))
  }
}
