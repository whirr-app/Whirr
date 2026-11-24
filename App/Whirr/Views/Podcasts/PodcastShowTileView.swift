import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The square-cover tile both the Podcasts root's bounded preview (`PodcastsView`) and the
/// all-shows page (`PodcastShowsView`) render for one podcast show, so the cover/title/publisher
/// layout lives in one place. Long-press context menus stay attached at each call site, since
/// they differ slightly by surface (`ItemContextMenu`'s `surface:` argument).
struct PodcastShowTileView: View {
  let show: ItemSummary
  let coverClient: any ArtworkServing
  let cardSize: CGFloat
  let wash: CoverWash?
  let attentionRow: PodcastsViewPresentation.ShowTileAttentionRow
  /// Where this show came from, drawn as a mark in the artwork's trailing corner rather than a
  /// caption line under the publisher. `nil` (the common case) for a tile that is not the marked
  /// exception, or that sits in a grid whose own title already answers the question.
  /// `PodcastsViewPresentation.showTileSourceMark` decides which.
  let sourceMark: PodcastsViewPresentation.ShowTileSourceMark?
  let onSelect: () -> Void

  init(
    show: ItemSummary,
    coverClient: any ArtworkServing,
    cardSize: CGFloat,
    wash: CoverWash? = nil,
    attentionRow: PodcastsViewPresentation.ShowTileAttentionRow = .omitted,
    sourceMark: PodcastsViewPresentation.ShowTileSourceMark? = nil,
    onSelect: @escaping () -> Void
  ) {
    self.show = show
    self.coverClient = coverClient
    self.cardSize = cardSize
    self.wash = wash
    self.attentionRow = attentionRow
    self.sourceMark = sourceMark
    self.onSelect = onSelect
  }

  var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        cover
          .aspectRatio(PodcastsViewPresentation.coverAspectRatio, contentMode: .fit)
          .frame(maxWidth: .infinity)

        // Each text area reserves its maximum line count, so a one-line title or missing
        // publisher doesn't leave a shorter tile than its neighbours. One reserving `Text` per
        // line, not a hidden sample behind it: tiles are built while scrolling, and the sample
        // doubled the text each one creates. The recovery line is reserved the same way, but
        // only when the grid shows it (`ShowTileAttentionRow`).
        Text(show.title)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(.primary)
          .lineLimit(PodcastsViewPresentation.showTileTitleReservedLineCount, reservesSpace: true)

        // A space, not an empty string: an empty `Text` reserves no line.
        let author = PodcastsViewPresentation.showTileAuthor(show.author)
        Text(author ?? " ")
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
          .lineLimit(1, reservesSpace: true)
          .accessibilityHidden(author == nil)

        if attentionRow != .omitted {
          Text(PodcastShowRecoveryPresentation.title)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WashInk.secondary)
            .lineLimit(1, reservesSpace: true)
            .opacity(attentionRow == .shown ? 1 : 0)
            .accessibilityHidden(attentionRow != .shown)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .editorialCardSurface(wash)
      // The cover's glow draws past the artwork; the card's own shape is where it stops.
      .clipShape(
        RoundedRectangle(
          cornerRadius: wash == nil ? 0 : EditorialCardSurfaceModifier.cornerRadius,
          style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    // The corner mark is decorative, so the source it stands for is spoken here.
    .accessibilityValue(sourceMark?.accessibilityLabel ?? "")
    .accessibilityHint(PodcastShowsViewPresentation.tileAccessibilityHint)
  }

  /// The tile's cover. It glows on a drained wash, as Home's covers do: podcast artwork is
  /// usually a flat square, and without the glow the dark tile has no colour beyond the cover.
  var cover: CoverImageView {
    CoverImageView(
      itemID: show.serverItemId, title: show.title,
      displaySize: cardSize, client: coverClient, source: show.providerArtworkSource,
      role: .homeCard,
      artworkMarks: CoverArtworkMarks(sourceSymbol: sourceMark?.symbolName),
      artworkGlow: true,
      revision: show.artworkRevision
    )
  }
}
