import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct ItemDetailHeroView: View {
  let item: ItemSummary
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let playback: PlaybackModel
  let displayScale: CGFloat
  let reduceMotion: Bool
  let isFinished: Bool
  let metadataLayout: ItemDetailMetadataLayout?
  let heroLayout: ItemDetailLayoutPresentation.Hero
  let readAffordance: ReadAffordanceState
  let onOpenMetadata: (ItemMetadataLink) -> Void

  /// The request stays the shared 272pt high-fidelity tier whichever size is drawn, so both hero
  /// shapes share one cache entry and palette. The column beside the artwork gives up its width,
  /// and the title's line cap follows (`ItemDetailHeroTextPresentation`).
  static let compactCoverSize: CGFloat = 140
  private static let compactCover = CoverMetrics(size: compactCoverSize)
  /// The promoted hero's artwork.
  ///
  /// The side of a square frame holding the `.fitTransparent` cover: a 0.65 trade paperback in
  /// 300pt is 300 tall and about 195 wide.
  ///
  /// The ceiling is the artwork fetched: `CoverRequest.quantizedWidth` rounds high-fidelity widths
  /// up to a 256px multiple, so 272pt asks for 816px at 3x and is served 1024. 300pt draws 900px
  /// (600 at 2x), inside that, so it never upscales. `displaySize` stays 272 because it keys the
  /// byte cache and palette. Vertically, with the narrator row a taller frame pushes the play
  /// capsule under the mini player on a 393×852pt phone.
  static let promotedCoverSize: CGFloat = 300
  /// Not proportional to the cover: that would be 17.6pt on the compact hero, with an 8.8pt check
  /// in a 1.3pt ring, unreadable.
  private static let coverBadgeSize: CGFloat = 28
  private static let coverBadgeInset: CGFloat = WhirrSpacing.xSmall
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  /// A book has no runtime to append a remainder to, so the remainder gets a line of its own, in
  /// the place and treatment an audiobook's duration line has.
  private var ebookRemainingText: String? {
    ItemDetailPlayButtonPresentation.ebookRemainingLabel(
      for: readAffordance, isFinished: isFinished)
  }

  // MARK: - Hero

  private var resolvedLayout: ItemDetailMetadataLayout {
    metadataLayout ?? ItemDetailMetadataLayout(item: item)
  }

  var body: some View {
    let layout = resolvedLayout
    return Group {
      switch heroLayout {
      case .stackedLeading:
        // Accessibility sizes keep the stacked, leading-set hero whatever the credit count. There
        // is no horizontal space to spend: the title alone runs to four or five lines, so a larger
        // cover pushes the read/play button off screen, and centring text that wraps that hard
        // hurts readability.
        VStack(alignment: .leading, spacing: WhirrSpacing.small) {
          cover(Self.compactCover)
          metadataColumn(layout: layout, alignment: .leading)
        }
      case .promotedStack:
        promotedHero(layout: layout)
      }
    }
    .frame(
      maxWidth: .infinity,
      alignment: heroLayout == .promotedStack ? .center : .leading)
  }

  /// Artwork first, large enough to be the subject of the page, with the credits set under it.
  ///
  /// Centred, not leading-set: a short credit block hung off the left edge of the cover leaves a
  /// hole beside the artwork.
  @ViewBuilder
  private func promotedHero(layout: ItemDetailMetadataLayout) -> some View {
    VStack(spacing: WhirrSpacing.small) {
      promotedCover
      metadataColumn(layout: layout, alignment: .center)
    }
    .frame(maxWidth: .infinity)
  }

  /// The promoted artwork fills the available content measure up to its tuned size.
  private var promotedCover: some View {
    GeometryReader { proxy in
      let size = min(Self.promotedCoverSize, proxy.size.width)
      cover(CoverMetrics(size: size))
    }
    .aspectRatio(1, contentMode: .fit)
    .frame(maxWidth: Self.promotedCoverSize)
  }

  @ViewBuilder
  private func cover(_ metrics: CoverMetrics) -> some View {
    let finishedBadgeMotion = ItemDetailViewPresentation.finishedBadgeMotion(
      reduceMotion: reduceMotion)
    CoverImageView(
      itemID: item.serverItemId, title: item.title,
      // The request is keyed by `DetailArtwork`, not by the drawn frame.
      displaySize: ItemDetailView.coverDisplaySize, client: coverClient, source: nil,
      author: item.author, role: .detail,
      // Fit a portrait cover whole, not cropping its title/author; the wash shows through the
      // margins. The radius rounds the fitted image (the square clip below only reaches the
      // margin). Navigation confines detail to audiobook/ebook, so no podcast reaches this hero.
      presentation: .fitTransparent,
      // The rim goes to the cover, not the frame below, because on a portrait ebook cover the two
      // are different rectangles. See `CoverImageView.Rim`.
      artworkRim: CoverImageView.Rim(color: Color.primary.opacity(0.12), lineWidth: 0.5),
      cornerRadius: metrics.cornerRadius,
      revision: item.artworkRevision
    )
    // Keyed on the revision as well: a replaced cover can land while the screen is open, once the
    // catalogue walk moves `updatedAt`.
    .task(id: item.artworkKeyIdentity) {
      let key = CoverPaletteService.artworkKey(
        itemID: item.serverItemId,
        coverClient: coverClient,
        displaySize: ItemDetailView.coverDisplaySize,
        displayScale: displayScale,
        role: .detail,
        revision: item.artworkRevision)
      await paletteService.show(
        CoverPaletteIdentity(key),
        bytes: .paletteSource(
          displayed: key, coverClient: coverClient))
    }
    .frame(width: metrics.size, height: metrics.size)
    .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
    // The rim is ink, following the page's pole, so it lifts the cover off a dark page where a
    // shadow can't. The shadow stays black (occlusion; ink-tinted it would be a pale smear) and
    // lifts the cover off a light page. Both scale with the frame. The shadow is cast from the
    // artwork's alpha, not this square, as a fitted cover's margins are transparent.
    .shadow(
      color: .black.opacity(0.24), radius: metrics.shadowRadius, y: metrics.shadowOffset
    )
    .accessibilityHidden(true)
    // Attached after `.accessibilityHidden(true)`: the artwork carries nothing VoiceOver needs,
    // but "Finished" does, so the badge keeps its own element.
    //
    // Pinned to the artwork's corner, not the frame's (a fitted ebook's margins would leave it
    // floating). Drawn outside the cover's clip so its shadow survives (`CoverArtworkBoundsKey`).
    .coverArtworkOverlay(alignment: .bottomTrailing) {
      if isFinished {
        FinishedCoverBadge(size: Self.coverBadgeSize)
          .padding(Self.coverBadgeInset)
          .transition(finishedBadgeMotion.transition)
      }
    }
    .animation(finishedBadgeMotion.animation, value: isFinished)
  }

  // No stack spacing: every credit line's names sit in `minimumTouchTarget`-tall rows, and that
  // height separates one line from the next. Credits that need a wider boundary ask for it
  // individually, so the title/author pairing stays as tight as elsewhere in the app.
  @ViewBuilder
  private func metadataColumn(
    layout: ItemDetailMetadataLayout, alignment: HeroColumnAlignment
  ) -> some View {
    VStack(alignment: alignment.stackAlignment, spacing: 0) {
      let seriesRow = ItemDetailMetadataPresentation.seriesRow(item: item, layout: layout)
      if seriesRow.reservesLayout {
        creditLine(
          links: [ItemMetadataLinkPresentation.seriesLink(seriesRow.text)].compactMap { $0 },
          placeholder: "Series",
          prominence: WhirrMetadataProminence.seriesName,
          alignment: alignment,
          isBreadcrumb: true)
      }

      Text(item.title)
        .font(WhirrTypeToken.title.font)
        .multilineTextAlignment(alignment.textAlignment)
        .lineLimit(
          ItemDetailHeroTextPresentation.titleLineLimit(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
        )
        .accessibilityAddTraits(.isHeader)
        .padding(.bottom, WhirrSpacing.xxSmall)

      // Author directly under the title, as on every other surface. The stat line is the only
      // thing in the hero that also steps down in size.
      let author = ItemMetadataLinkPresentation.personLinks(item.author, role: .author)
      if author.isEmpty == false {
        creditLine(
          links: author, prominence: WhirrMetadataProminence.authorName,
          alignment: alignment, leadIn: "Written by")
      }

      let narratorRow = ItemDetailMetadataPresentation.narratorRow(item: item, layout: layout)
      // No extra padding between the two credits: the lead-ins name each row, so the boundary
      // needs no whitespace, and the block keeps the pitch of its title-to-author pair.
      if narratorRow.reservesLayout {
        creditLine(
          links: ItemMetadataLinkPresentation.personLinks(
            narratorRow.text, role: .narrator),
          placeholder: "Narrator",
          prominence: WhirrMetadataProminence.authorName,
          alignment: alignment,
          leadIn: "Narrated by"
        )
      }

      // The stat carries its own top padding (`ItemDetailStatLineBody`): the audio line decides
      // whether to draw at all and must take the padding with it when it doesn't.
      if let heroStat {
        statLine(heroStat, alignment: alignment)
      }
    }
    .multilineTextAlignment(alignment.textAlignment)
    .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
  }

  /// Which kind of stat the hero may print, decided without reading the playhead: an audio title
  /// with a runtime, or an ebook with a remainder. Whether an audio title is part-played, and so
  /// whether the line draws, is `ItemDetailDurationLine`'s, since only it reads the playhead.
  private enum HeroStat {
    /// An audio title with a runtime: the line draws its bar and remainder while part-played.
    case audioProgress
    /// A book has no runtime, so the remainder stands in for one.
    case ebookRemaining(String)
  }

  private var heroStat: HeroStat? {
    if let durationSeconds = item.durationSeconds,
      ItemDetailDurationPresentation.showsDuration(
        category: item.category, durationSeconds: durationSeconds)
    {
      return .audioProgress
    }
    if item.category == .ebook, let remaining = ebookRemainingText {
      return .ebookRemaining(remaining)
    }
    return nil
  }

  /// A stat, not a name: the ladder's dimmest rung, set apart from the credits by size rather than
  /// another step down. There is no room below it, and the page's lightness band is solved so
  /// this rung stays legible on every cover.
  @ViewBuilder
  private func statLine(_ stat: HeroStat, alignment: HeroColumnAlignment) -> some View {
    switch stat {
    case .audioProgress:
      ItemDetailDurationLine(
        item: item,
        playback: playback,
        isFinished: isFinished,
        alignment: alignment)
    case .ebookRemaining(let remaining):
      // A book has no runtime, so this line is the remainder, drawn through the same
      // `ItemDetailStatLineBody` as the audio stat so the two cannot drift apart. Both figures
      // come from the same reading state, so the remainder is present when the fraction is.
      if let fraction = ItemDetailPlayButtonPresentation.ebookProgressFraction(
        for: readAffordance, isFinished: isFinished)
      {
        ItemDetailStatLineBody(lead: remaining, progressFraction: fraction, alignment: alignment)
      }
    }
  }

  /// One credit line, built here so the hero's call sites stay one line each. The line is
  /// `ItemDetailCreditLine`, a view because each line owns whether its overflow is open, and that
  /// state has to survive the hero rebuilding when the expanded metadata lands.
  private func creditLine(
    links: [ItemMetadataLink], placeholder: String? = nil,
    prominence: WhirrMetadataProminence, alignment: HeroColumnAlignment,
    leadIn: String? = nil,
    isBreadcrumb: Bool = false
  ) -> some View {
    ItemDetailCreditLine(
      links: links, placeholder: placeholder, prominence: prominence,
      alignment: alignment, leadIn: leadIn,
      onOpenMetadata: onOpenMetadata, isBreadcrumb: isBreadcrumb)
  }
}

/// Which way the hero's text is set. Not a bare `HorizontalAlignment`, because a credit line also
/// has to swap flow layouts: a centred flow must centre each wrapped row on its own.
enum HeroColumnAlignment {
  case leading
  case center

  var stackAlignment: HorizontalAlignment { self == .leading ? .leading : .center }
  var textAlignment: TextAlignment { self == .leading ? .leading : .center }
  var frameAlignment: Alignment { self == .leading ? .leading : .center }
}

/// The size-dependent half of the artwork treatment. Both hero shapes draw the same requested
/// image at different sizes, so the clip corner and shadow follow the drawn frame, not the
/// request tier.
private struct CoverMetrics {
  let size: CGFloat

  private var scale: CGFloat { size / ItemDetailView.coverDisplaySize }
  var cornerRadius: CGFloat { 18 * scale }
  var shadowRadius: CGFloat { 20 * scale }
  var shadowOffset: CGFloat { 12 * scale }
}
