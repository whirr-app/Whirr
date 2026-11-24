import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The run of books that belong to no series, laid out in the same two columns a series card uses.
///
/// One section per book, not one shared card: a card claims its contents belong together, and a
/// "Standalone" collection would wash unrelated books in whichever cover came first (the wash
/// store keys on the section). Tiles, not full-width rows, since a book often lacks duration or
/// narrator.
struct AuthorSeriesStandaloneBookGrid: View {
  let sections: [AuthorSeriesSection]
  let target: AuthorSeriesModel.Target
  let washSourceItemID: (AuthorSeriesSection) -> String?
  let wash: (AuthorSeriesSection) -> CoverWash
  let coverClient: any ArtworkServing
  let playbackProgress: (String) -> ItemPlaybackProgress?
  let finishedStatus: FinishedStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelectItem: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void
  let onRequestWash: (String) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var containerWidth: CGFloat = 0

  var body: some View {
    LazyVGrid(
      columns: columns,
      alignment: .leading,
      spacing: AuthorSeriesGridMetrics.gridSpacing
    ) {
      ForEach(sections) { section in
        AuthorSeriesStandaloneCard(
          section: section,
          target: target,
          tileWidth: tileWidth,
          coverShape: coverShape,
          sourceItemID: washSourceItemID(section),
          wash: wash(section),
          coverClient: coverClient,
          playbackProgress: playbackProgress,
          finishedStatus: finishedStatus,
          playback: playback,
          actions: actions,
          onSelectItem: onSelectItem,
          onPresentReader: onPresentReader,
          onSearch: onSearch,
          onRequestWash: onRequestWash)
      }
    }
    // The run measures the page's content width directly: unlike a section card there is no chrome
    // between the scroll view and these columns, so the card padding belongs to each tile instead.
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      containerWidth = $0
    }
  }

  private var columnCount: Int {
    AuthorSeriesGridMetrics.columnCount(
      forContentWidth: containerWidth,
      minimumTileWidth: AuthorSeriesGridMetrics.columnMinimumWidth(
        forTileMinimumWidth: minimumTileWidth))
  }

  private var columnWidth: CGFloat {
    AuthorSeriesGridMetrics.tileWidth(forContentWidth: containerWidth, columns: columnCount)
  }

  private var tileWidth: CGFloat {
    AuthorSeriesGridMetrics.tileWidth(insideColumnWidth: columnWidth)
  }

  /// The run is one grid even though each book carries its own card, so the shape is chosen across
  /// every book in it: two neighbouring cards drawn to different cover heights would step.
  private var coverShape: AuthorSeriesCoverShape {
    AuthorSeriesCoverShape.shape(for: sections.flatMap(\.rows))
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(
        .fixed(columnWidth), spacing: AuthorSeriesGridMetrics.gridSpacing, alignment: .top),
      count: columnCount)
  }

  private var minimumTileWidth: CGFloat {
    dynamicTypeSize.isAccessibilitySize
      ? AuthorSeriesGridMetrics.accessibilityCoverTileMinimumWidth
      : AuthorSeriesGridMetrics.coverTileMinimumWidth
  }
}

/// One loose book's card. The wash request lives here rather than on the tile because a request is
/// made per section, and on this screen a section is what owns a colour.
struct AuthorSeriesStandaloneCard: View {
  let section: AuthorSeriesSection
  let target: AuthorSeriesModel.Target
  let tileWidth: CGFloat
  let coverShape: AuthorSeriesCoverShape
  let sourceItemID: String?
  let wash: CoverWash
  let coverClient: any ArtworkServing
  let playbackProgress: (String) -> ItemPlaybackProgress?
  let finishedStatus: FinishedStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelectItem: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void
  let onRequestWash: (String) -> Void

  var body: some View {
    if let row = section.rows.first {
      AuthorSeriesGridTile(
        row: row,
        section: section,
        target: target,
        tileWidth: tileWidth,
        coverShape: coverShape,
        wash: wash,
        drawsOwnCardSurface: true,
        coverClient: coverClient,
        playbackProgress: playbackProgress(row.entityID),
        finishedStatus: finishedStatus,
        playback: playback,
        actions: actions,
        onSelectItem: onSelectItem,
        onPresentReader: onPresentReader,
        onSearch: onSearch
      )
      .onAppear { requestWash() }
      .onChange(of: sourceItemID) { _, _ in requestWash() }
    }
  }

  private func requestWash() {
    guard let sourceItemID else { return }
    onRequestWash(sourceItemID)
  }
}
