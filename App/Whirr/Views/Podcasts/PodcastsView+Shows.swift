import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

extension PodcastsView {
  private struct ShowTileFacts: Identifiable {
    let show: ItemSummary
    let needsAttention: Bool
    let isServerSourced: Bool

    var id: String { show.id }
  }

  private struct ShowTileRow: Identifiable {
    let tiles: [ShowTileFacts]

    var id: String { tiles.first?.id ?? "" }
  }

  /// A grid, not a row: shows are a collection you browse, not a strip you scrub sideways past
  /// the ones that happen to sort first.
  func showsSection(_ shows: [ItemSummary]) -> some View {
    let tiles = shows.map { show in
      ShowTileFacts(
        show: show,
        needsAttention: nativeShowsModel.needsAttention(itemID: show.serverItemId),
        isServerSourced: PodcastsViewPresentation.showTileIsServerSourced(show))
    }
    let gridNeedsAttention = tiles.contains { $0.needsAttention }
    let gridMixesSources = PodcastsViewPresentation.gridMixesSources(
      tilesAreServerSourced: tiles.map(\.isServerSourced))
    return showsGrid(
      tiles, gridNeedsAttention: gridNeedsAttention, gridMixesSources: gridMixesSources
    )
    .padding(.horizontal, pageColumnInset)
    .onAppear {
      // Synchronous, so washes `PodcastsRootArrivalWarmup` already lifted into memory colour the
      // tiles in the update that first draws them; the page's preload task lands a frame later.
      homeWashProvider.seedCachedWashes(shows.map(\.washSubject))
      homeWashProvider.request(
        shows.map(\.washSubject), intent: .bulk, displaySize: Self.cardSize, displayScale: displayScale,
        artworkRole: .homeCard)
    }
  }

  /// Lazy only where the list is unbounded (`showsGridIsLazy`). The eager rows match the lazy
  /// grid's flexible columns: equal widths, top-aligned, with a short last row padded by empty
  /// columns.
  @ViewBuilder
  private func showsGrid(
    _ tiles: [ShowTileFacts], gridNeedsAttention: Bool, gridMixesSources: Bool
  ) -> some View {
    if PodcastsViewPresentation.showsGridIsLazy(filter: filter) {
      LazyVGrid(columns: showColumns, alignment: .leading, spacing: WhirrSpacing.medium) {
        ForEach(tiles) { tile in
          showTile(
            tile.show,
            gridNeedsAttention: gridNeedsAttention,
            needsAttention: tile.needsAttention,
            isServerSourced: tile.isServerSourced,
            gridMixesSources: gridMixesSources)
        }
      }
    } else {
      let columns = PodcastsViewPresentation.showGridRowColumnCount(
        columnWidth: pageColumnWidth, tileWidth: showTileWidth)
      let rows = PodcastsViewPresentation.showGridRows(tiles, columns: columns)
        .map(ShowTileRow.init(tiles:))
      VStack(alignment: .leading, spacing: WhirrSpacing.medium) {
        ForEach(rows) { row in
          HStack(alignment: .top, spacing: WhirrSpacing.small) {
            ForEach(row.tiles) { tile in
              showTile(
                tile.show,
                gridNeedsAttention: gridNeedsAttention,
                needsAttention: tile.needsAttention,
                isServerSourced: tile.isServerSourced,
                gridMixesSources: gridMixesSources
              )
              .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            ForEach(row.tiles.count..<max(columns, row.tiles.count), id: \.self) { _ in
              Color.clear
                .frame(height: 0)
                .frame(maxWidth: .infinity)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  func showsGridSection(
    title: String, onSelect: @escaping () -> Void, shows: [ItemSummary], totalShowCount: Int,
    isFirst: Bool
  ) -> some View {
    BrowseSectionHeaderView(
      title: title,
      accessibilityHint: PodcastsViewPresentation.showsHeadingAccessibilityHint,
      onSelect: onSelect
    )
    .padding(.horizontal, pageColumnInset)
    .padding(.top, HomePodcastsBrowseLayout.shelfTopSpacing(isFirst: isFirst))
    .padding(.bottom, HomePodcastsBrowseLayout.headerToContentSpacing)

    showsSection(shows)
      .padding(.bottom, WhirrSpacing.medium)

    if let footerTitle = PodcastsViewPresentation.showsFooterTitle(
      totalCount: totalShowCount, shownCount: shows.count)
    {
      showsFooter(title: footerTitle, onSelect: onSelect)
        .padding(.horizontal, pageColumnInset)
        .padding(.bottom, WhirrSpacing.medium)
    }
  }

  /// A row, not a tile: a "More" card among the artwork reads as a show with missing art, takes a
  /// real show's slot, and leaves a hole whenever the count does not fill the last row. Same
  /// destination and chevron as the heading, so the grid has one route out at each end.
  private func showsFooter(title: String, onSelect: @escaping () -> Void) -> some View {
    Button(action: onSelect) {
      HStack {
        Text(title)
          .font(.body.weight(.semibold))
          .foregroundStyle(.primary)
        Spacer(minLength: WhirrSpacing.small)
        Image(systemName: "chevron.right")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(title)
    .accessibilityHint(PodcastsViewPresentation.showsHeadingAccessibilityHint)
  }

  private var showTileWidth: CGFloat {
    PodcastsViewPresentation.showGridTileWidth(
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  /// An explicit column count, not `.adaptive(minimum:)`: `showGridColumnCount` computes it from
  /// the page column's width, the same width and formula the preview limit reads, so the grid and
  /// the limit agree on how many columns fit.
  private var showColumns: [GridItem] {
    let tileWidth = showTileWidth
    // Before the first geometry pass the width is unknown; the adaptive column sizes from the
    // proposed width instead of collapsing the grid to one column for that frame.
    guard pageColumnWidth.isFinite, pageColumnWidth > 0 else {
      return [GridItem(.adaptive(minimum: tileWidth), spacing: WhirrSpacing.small, alignment: .top)]
    }
    let columnCount = PodcastsViewPresentation.showGridColumnCount(
      columnWidth: pageColumnWidth, tileWidth: tileWidth)
    return Array(
      repeating: GridItem(.flexible(), spacing: WhirrSpacing.small, alignment: .top),
      count: columnCount)
  }

  /// The tile (cover, title, publisher) is shared with the all-shows page via
  /// `PodcastShowTileView`, so both surfaces render one layout. The context menu is attached here
  /// rather than inside the shared view, as in `PodcastShowsView.showTile`.
  private func showTile(
    _ show: ItemSummary,
    gridNeedsAttention: Bool,
    needsAttention: Bool,
    isServerSourced: Bool,
    gridMixesSources: Bool
  ) -> some View {
    PodcastShowTileView(
      show: show, coverClient: coverClient, cardSize: Self.cardSize,
      wash: homeWashProvider.wash(for: show.washSubject),
      attentionRow: PodcastsViewPresentation.showTileAttentionRow(
        needsAttention: needsAttention,
        gridNeedsAttention: gridNeedsAttention),
      sourceMark: PodcastsViewPresentation.showTileSourceMark(
        isServerSourced: isServerSourced, gridMixesSources: gridMixesSources),
      onSelect: {
        switch PodcastsViewPresentation.showTileEpisodeFilter(for: filter) {
        case .downloaded: onSelectDownloadedShow(show)
        default: onSelectShow(show)
        }
      }
    )
    .onAppear {
      homeWashProvider.request(
        [show.washSubject], intent: .visible, displaySize: Self.cardSize, displayScale: displayScale,
        artworkRole: .homeCard)
    }
    .itemContextMenu(
      ItemMenuSubject(
        show: show, coverClient: coverClient, playback: playback, actions: actions),
      placement: .podcastsTabShowTile,
      onOpen: { onSelectShow(show) },
      onSearch: onSearch)
  }
}
