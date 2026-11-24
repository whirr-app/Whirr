import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// One editorial section owns its wash and its item-state dependencies. Keeping wash requests at
/// section scope prevents every tile from creating its own palette work, while the adaptive grid
/// keeps source order row-major and lets Dynamic Type choose a genuinely readable minimum width.
struct AuthorSeriesGridSection: View {
  let section: AuthorSeriesSection
  let target: AuthorSeriesModel.Target
  let hasMore: Bool
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

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var cardWidth: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: AuthorSeriesGridMetrics.gridSpacing) {
      if AuthorSeriesCopy.showsCardHeader(for: section, target: target) {
        heading
      }

      LazyVGrid(
        columns: columns,
        alignment: .leading,
        spacing: AuthorSeriesGridMetrics.gridSpacing
      ) {
        ForEach(section.rows) { row in
          AuthorSeriesGridTile(
            row: row,
            section: section,
            target: target,
            tileWidth: tileWidth,
            coverShape: coverShape,
            wash: wash,
            coverClient: coverClient,
            playbackProgress: playbackProgress(row.entityID),
            finishedStatus: finishedStatus,
            playback: playback,
            actions: actions,
            onSelectItem: onSelectItem,
            onPresentReader: onPresentReader,
            onSearch: onSearch)
        }
      }
    }
    // Always the full container width, so the measurement below is the card's own geometry and
    // never the width of whatever the grid laid out, which would feed back into the column count.
    .frame(maxWidth: .infinity, alignment: .leading)
    .editorialCardSurface(wash)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      cardWidth = $0
    }
    .onAppear { requestWash() }
    .onChange(of: sourceItemID) { _, _ in requestWash() }
  }

  /// The card's inner width. The wash reaching this view is already resolved (the screen falls back
  /// to `.neutral`), so the chrome and its padding are always applied.
  private var contentWidth: CGFloat {
    max(0, cardWidth - 2 * EditorialCardSurfaceModifier.contentPadding)
  }

  private var columnCount: Int {
    AuthorSeriesGridMetrics.columnCount(
      forContentWidth: contentWidth, minimumTileWidth: minimumTileWidth)
  }

  /// Before the first measurement lands this is the minimum rather than zero, so the one frame
  /// between creation and layout draws a tile close to its settled size instead of a collapsed one.
  private var tileWidth: CGFloat {
    AuthorSeriesGridMetrics.tileWidth(forContentWidth: contentWidth, columns: columnCount)
  }

  /// One shape for the whole card, so its rows keep a single title baseline.
  private var coverShape: AuthorSeriesCoverShape {
    AuthorSeriesCoverShape.shape(for: section.rows)
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(
        .fixed(tileWidth), spacing: AuthorSeriesGridMetrics.gridSpacing, alignment: .top),
      count: columnCount)
  }

  private var minimumTileWidth: CGFloat {
    dynamicTypeSize.isAccessibilitySize
      ? AuthorSeriesGridMetrics.accessibilityCoverTileMinimumWidth
      : AuthorSeriesGridMetrics.coverTileMinimumWidth
  }

  private var heading: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: AuthorSeriesGridMetrics.gridSpacing) {
        headingText
        Spacer(minLength: AuthorSeriesGridMetrics.gridSpacing)
        if let editionCount = editionCountText {
          countText(editionCount)
        }
      }

      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        headingText
        if let editionCount = editionCountText {
          countText(editionCount)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isHeader)
    .accessibilityLabel(
      AuthorSeriesCopy.cardHeadingLabel(for: section, hasMore: hasMore)
    )
  }

  private var editionCountText: String? {
    AuthorSeriesCopy.itemCountText(for: section, hasMore: hasMore)
  }

  private var headingText: some View {
    Text(AuthorSeriesCopy.cardHeading(for: section))
      .font(WhirrTypeToken.display.font)
      .foregroundStyle(WhirrColorToken.textPrimary.color)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(1)
  }

  private func countText(_ text: String) -> some View {
    Text(text)
      .font(WhirrTypeToken.caption.font)
      .foregroundStyle(WashInk.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func requestWash() {
    guard let sourceItemID else { return }
    onRequestWash(sourceItemID)
  }
}
