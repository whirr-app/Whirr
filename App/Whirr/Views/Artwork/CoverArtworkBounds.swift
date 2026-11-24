import SwiftUI

/// Where the artwork ended up inside the box drawn around it, sent up to whatever draws on top of
/// the cover.
///
/// Marks and rim travel down into `CoverImageView`; a caller's badge can't (own accent,
/// transition and accessibility element, drawn outside the clip so its shadow isn't cut), so the
/// geometry moves up instead.
///
/// The only place the app reads layout back out of a subtree. Admissible because it is bounded: a
/// detail hero's cover changes shape at most once, when the image lands. Nothing scroll-driven may
/// use it.
struct CoverArtworkBoundsKey: PreferenceKey {
  nonisolated static var defaultValue: Anchor<CGRect>? { nil }

  /// Last writer wins, and a child that reported nothing never clears one that did.
  nonisolated static func reduce(
    value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?
  ) {
    value = nextValue() ?? value
  }
}

extension View {
  /// Reports these bounds as the artwork's, for `coverArtworkOverlay(alignment:content:)`.
  func reportsCoverArtworkBounds() -> some View {
    anchorPreference(key: CoverArtworkBoundsKey.self, value: .bounds) { $0 }
  }

  /// Overlays `content` on the artwork inside this view rather than on the view's own bounds.
  ///
  /// Falls back to those bounds when nothing underneath reported any, so a caller overlaying
  /// something that is not a cover gets exactly `.overlay(alignment:)`.
  func coverArtworkOverlay<Content: View>(
    alignment: Alignment, @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    overlayPreferenceValue(CoverArtworkBoundsKey.self) { anchor in
      GeometryReader { proxy in
        let artwork = anchor.map { proxy[$0] } ?? CGRect(origin: .zero, size: proxy.size)
        content()
          .frame(width: artwork.width, height: artwork.height, alignment: alignment)
          .offset(x: artwork.minX, y: artwork.minY)
      }
    }
  }
}
