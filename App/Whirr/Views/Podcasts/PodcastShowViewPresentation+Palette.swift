import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

nonisolated extension PodcastShowViewPresentation {
  /// The show is the palette identity for both its header and every episode row.
  static func washKey(for itemID: String) -> String { itemID }

  /// The glyph beside the header's source caption: the feed glyph for a followed feed, the server
  /// drive for an Audiobookshelf show, so the two captions differ by more than their wording.
  static func sourceCaptionSymbolName(for itemID: String) -> String {
    switch PodcastShowSourcePresentation.source(itemID: itemID) {
    case .audiobookshelf: PodcastShowHeaderView<EmptyView>.serverCaptionSymbolName
    case .rssFeed, nil: PodcastShowHeaderView<EmptyView>.feedCaptionSymbolName
    }
  }

  /// Resolves the page's artwork identity without making the view rediscover metadata. A route
  /// seed is the strongest answer, followed by the shell's synchronous followed-show lookup, then
  /// the item's eventual live projection.
  static func pageArtworkSource(
    seed: ItemSummary?, resolverSource: ArtworkSource?, loadedItem: ItemSummary?
  ) -> ArtworkSource? {
    seed?.providerArtworkSource ?? resolverSource ?? loadedItem?.providerArtworkSource
  }

  /// Height of the washed top region, from the physical top edge (the wash runs behind the
  /// navigation bar). 360 points clears the bar, header and chips on compact sizes; a constant,
  /// not measured, so a taller header just finishes the fade further up.
  static let headerWashHeight: CGFloat = 360

  /// Where the fade starts, as a fraction of `headerWashHeight`: solid first, then fading over the
  /// remaining ~215 points (a fade from the top edge reads as a gradient, not a coloured page).
  static let headerWashSolidFraction: Double = 0.4

  /// The header cover glows as Home's covers do: dark only, where the drained fade alone barely
  /// shows. On paper the light fade carries the show's colour, and a glow there hardly reads.
  static let headerCoverGlows = true

  /// How far to translate the wash so it leaves with the header. Clamped to keep observation
  /// cheap: below zero (rubber-banding) it would peel off the top edge and fire every
  /// pull-to-refresh frame; above `headerWashHeight` every offset draws the same frame.
  static func washOffset(contentOffsetY: CGFloat, topInset: CGFloat) -> CGFloat {
    min(max(0, contentOffsetY + topInset), headerWashHeight)
  }

  /// How much of the show's cover this screen spends, and where.
  ///
  /// No surface takes a fill. The cover's hue survives as `accent` (row glyph, progress bar,
  /// selected chip) and `headerWash` behind the top region.
  nonisolated struct ShowPalette {
    /// The wash to fill the header card with, or nil for no card at all.
    let headerFill: CoverWash?
    /// The wash to fill each episode row's card with, or nil for a row drawn on the page itself.
    let episodeRowFill: CoverWash?
    /// The mark colour, or nil when the cover was too grey to yield one. This is the band as
    /// `CoverWash` designed it (the screen's identity), and the selected filter chip takes it as
    /// a fill, where `MediaFilterPicker` pairs it with an ink it can carry.
    let accent: Color?
    /// The same accent as a mark laid on the page, which is a different problem: the band is
    /// placed for weight, and on the light page wash it reaches 2.67:1 at its worst, under the
    /// 3:1 SC 1.4.11 asks of a progress bar or a status glyph. Nil when `accent` is.
    let pageMark: Color?
    /// The wash painted behind the top of the page, or nil for a page with no washed region.
    let headerWash: CoverWash?

    var usesWashAccent: Bool { accent != nil }
    /// Rows with no card of their own need a hairline to be told apart; a card row separates
    /// itself. Derived, so the two cannot disagree.
    var separatesEpisodeRows: Bool { episodeRowFill == nil }
  }

  static func palette(for wash: CoverWash) -> ShowPalette {
    // A neutral wash yields no region at all. Its light and dark values sit within a few percent
    // of the editorial background, so a gradient between them would cost a layer to render a
    // smudge; the same greyness that leaves `accentColor` nil is what disqualifies the region.
    let accent = wash.accentColor
    return ShowPalette(
      headerFill: nil, episodeRowFill: nil, accent: accent,
      pageMark: wash.accentColor(on: .page, minimumRatio: 3),
      headerWash: accent == nil ? nil : wash)
  }
}
