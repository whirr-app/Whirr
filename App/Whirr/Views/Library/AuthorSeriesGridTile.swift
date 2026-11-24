import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// A direct item control for the cover grid. The artwork frame is one box at the tile's own width,
/// chosen by the grid rather than by this row, so every cover in a row draws to one shape and one
/// baseline whatever the server sent. `.fitTransparent` preserves a cover the box does not match,
/// and the explicit image radius rounds the fitted artwork itself rather than relying on the
/// frame's transparent margins to clip it.
struct AuthorSeriesGridTile: View {
  let row: SearchResultRow
  let section: AuthorSeriesSection
  let target: AuthorSeriesModel.Target
  let tileWidth: CGFloat
  /// The grid's box, not this row's own shape: a tile that sized its cover to its own artwork would
  /// step its title against the tile beside it.
  let coverShape: AuthorSeriesCoverShape
  let wash: CoverWash
  /// A loose book paints its own card, because it is its own section and its own colour. A tile
  /// inside a section card paints nothing: that card already carries one wash for all of them.
  var drawsOwnCardSurface: Bool = false
  let coverClient: any ArtworkServing
  let playbackProgress: ItemPlaybackProgress?
  let finishedStatus: FinishedStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelectItem: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.bookZoomTransitionContext) private var bookZoomTransition
  @Environment(\.bookZoomTransitionOccurrencePrefix) private var bookZoomOccurrencePrefix

  var body: some View {
    let summary = AuthorSeriesRowPresentation.itemSummary(for: row)
    let occurrence = "\(bookZoomOccurrencePrefix)/author-series/\(section.id)/\(row.entityID)"
    // The playhead is read inside the reader, below the context menu, so a tick moves the playing
    // book's bar without rebuilding an open menu; see `DisplayedPositionReader`. Reading progress
    // has no playhead, so only an audiobook asks.
    DisplayedPositionReader(
      playback: playback, itemID: row.entityID, episodeID: nil,
      persisted: row.mediaCategory == .audiobook ? playbackProgress?.currentTime : nil
    ) { positionSeconds in
      tileButton(summary: summary, occurrence: occurrence, positionSeconds: positionSeconds)
    }
    .modifier(
      SearchItemContextMenuModifier(
        row: row,
        menu: SearchViewPresentation.contextMenu(for: row),
        coverClient: coverClient,
        finishedStatus: finishedStatus,
        playback: playback,
        actions: actions,
        onSelectItem: { self.selectItem(summary, occurrence: occurrence) },
        onPresentReader: onPresentReader,
        onSearch: onSearch))
  }

  /// Two lines of reserved height at regular sizes, so a one-line title and a two-line title in the
  /// same row put their sequence, badges, and duration on the same baselines instead of stepping.
  /// An accessibility size drops both the reservation and the limit: there the grid is one column,
  /// nothing has to align, and a truncated title is the worse outcome.
  @ViewBuilder private var title: some View {
    let text =
      Text(row.title)
      .font(WhirrTypeToken.headline.font)
      .foregroundStyle(WhirrColorToken.textPrimary.color)

    if dynamicTypeSize.isAccessibilitySize {
      text.fixedSize(horizontal: false, vertical: true)
    } else {
      text.lineLimit(2, reservesSpace: true)
    }
  }

  /// The stored progress at the displayed position, when `DisplayedPositionReader` resolved one.
  private func displayedProgress(positionSeconds: Double?) -> ItemPlaybackProgress? {
    guard let playbackProgress, let positionSeconds else { return playbackProgress }
    return ItemPlaybackProgress(
      currentTime: positionSeconds,
      ebookProgress: playbackProgress.ebookProgress, isFinished: playbackProgress.isFinished)
  }

  private func tileButton(
    summary: ItemSummary, occurrence: String, positionSeconds: Double?
  ) -> some View {
    let playbackStatus = finishedStatus.playbackStatus(row.entityID)
    let progressFraction = AuthorSeriesRowPresentation.progressFraction(
      for: row, progress: displayedProgress(positionSeconds: positionSeconds),
      status: playbackStatus)
    // The bar is the richer in-progress treatment, so the mark only speaks when the bar is silent,
    // or when the state is finished, which no bar can say.
    let status = LibraryBrowsePresentation.rowPlaybackStatus(playbackStatus: playbackStatus)
    let coverMark = (status == .finished || progressFraction == nil) ? status : nil

    return Button {
      selectItem(summary, occurrence: occurrence)
    } label: {
      let tile = VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        CoverImageView(
          itemID: row.entityID,
          title: row.title,
          displaySize: AuthorSeriesGridMetrics.coverDisplaySize,
          client: coverClient,
          source: nil,
          author: row.subtitle,
          role: .homeCard,
          presentation: .fitTransparent,
          // Every cover starts at the top of its frame, so a row of them shares one edge whatever
          // shape the server sent.
          fitAlignment: .top,
          // Both marks sit on the artwork, as on every other screen. Inline, they shared a line
          // with the sequence and duration and a tile this narrow wrapped all three. The cover
          // places them because a cover whose shape does not match the grid's box does not reach
          // the box's corners.
          artworkMarks: CoverArtworkMarks(
            stateSymbol: coverMark?.systemImage,
            mediaKind: AuthorSeriesRowPresentation.mediaBadge(for: row)?.kind),
          cornerRadius: AuthorSeriesGridMetrics.coverCornerRadius,
          revision: row.artworkRevision
        )
        .frame(
          width: tileWidth,
          height: AuthorSeriesGridMetrics.coverHeight(forTileWidth: tileWidth, shape: coverShape)
        )
        .bookZoomTransitionSource(bookZoomTransition?.source(item: summary, occurrence: occurrence))

        title

        // One line for everything the tile says in words.
        if let detail = AuthorSeriesRowPresentation.tileDetail(for: row) {
          Text(detail)
            .font(WhirrTypeToken.subheadline.font)
            .foregroundStyle(WashInk.secondary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
        }

        if let progressFraction {
          PlaybackProgressBar(
            fraction: progressFraction,
            tint: wash.accentColor ?? PlaybackProgressBar.progressTint
          )
          .accessibilityHidden(true)
        }
      }
      // No minimum height: the portrait cover alone clears the touch target several times over.
      .frame(width: tileWidth, alignment: .topLeading)

      if drawsOwnCardSurface {
        tile
          // Fills the grid row's height, so two cards side by side paint to one bottom edge even
          // when one is an ebook with no duration line and the other carries a progress bar.
          .frame(maxHeight: .infinity, alignment: .top)
          .editorialCardSurface(wash)
          .contentShape(.rect)
      } else {
        tile.contentShape(.rect)
      }
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      AuthorSeriesRowPresentation.accessibilityLabel(
        for: row, in: section, target: target, playbackStatus: playbackStatus,
        progressFraction: progressFraction)
    )
  }

  private func selectItem(_ summary: ItemSummary, occurrence: String) {
    if let bookZoomTransition,
      bookZoomTransition.selectBook(
        summary, occurrence: occurrence, artworkRole: .homeCard,
        displaySize: AuthorSeriesGridMetrics.coverDisplaySize)
    {
    } else {
      onSelectItem(summary)
    }
  }
}
