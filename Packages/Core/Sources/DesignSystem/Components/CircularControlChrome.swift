import SwiftUI

extension View {
  /// A secondary control's body: a filled circle, inside a touch target that may be larger than it.
  ///
  /// The fill matters: a bare glyph meets the hit minimum but reads as a mark, not a button, beside
  /// a filled primary control. Its weight is the caller's, since the same circle sits next to a
  /// filled capsule (needs presence) and next to a title (anything heavier competes).
  ///
  /// `hitTargetDiameter` separates drawing size from touch size: drawing at the touch minimum makes
  /// a secondary control look primary. The caller sets the glyph's own font first.
  public func circularControlChrome<Fill: ShapeStyle>(
    diameter: CGFloat,
    hitTargetDiameter: CGFloat,
    fill: Fill
  ) -> some View {
    let target = max(diameter, hitTargetDiameter)
    return
      frame(width: diameter, height: diameter)
      .background(fill, in: Circle())
      .frame(width: target, height: target)
      // The circle is the target, not the glyph: `.plain` otherwise shrinks the hit area to the
      // drawn symbol, which for an ellipsis is a few points wide.
      .contentShape(Circle())
  }
}
