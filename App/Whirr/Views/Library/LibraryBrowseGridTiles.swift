import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

// The regular-width Library tiles, shared by the collection-view host and, until the SwiftUI grid
// is retired, by `LibraryBrowseGridViews`. Each tile's width is the resolved column width; the
// tile never measures its container.

/// A full-tile title button. The title and its metadata expand for accessibility sizes rather than
/// truncating essential text, while ordinary sizes reserve two title lines for aligned grid rows.
struct LibraryTitleGridTile: View {
  let item: ItemSummary
  let tileWidth: CGFloat
  let prefetchIndex: Int
  let orderedIDs: [String]
  let revisionsByID: [String: ArtworkRevision]
  let coverClient: any ArtworkServing
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let artworkPrefetcher: DirectionalArtworkPrefetcher
  let onSelect: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void
  /// False in a reused collection-view cell, where `onAppear` no longer means "newly visible";
  /// the host drives the prefetcher from `willDisplay` instead.
  var prefetchesOnAppear = true

  @Environment(\.displayScale) private var displayScale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.bookZoomTransitionContext) private var bookZoomTransition

  // The floor-arm branch sits behind the preprocessor, not just `HarnessSwitch.usesFloorTile`.
  // `body` is an implicit `@ViewBuilder`, so an `if`/`else` becomes a compile-time `buildEither`
  // and the body's type is `_ConditionalContent` whatever the switch folds to, adding a wrapper
  // node to every release tile. Release gets the straight-line body; the harness pays for its arm.
  #if DEBUG || PERF_INVESTIGATION
    var body: some View {
      // Both arms keep the `Tile.construct` span and the body counter, so a floor sweep reports
      // the same per-tile census as the control.
      if HarnessSwitch.usesFloorTile {
        harnessTimedSpan("Tile.construct") { floorTileBody }
      } else {
        harnessTimedSpan("Tile.construct") { tileBody }
      }
    }

    private var floorTileBody: some View {
      LibraryTitleGridFloorTile(
        item: item,
        tileWidth: tileWidth,
        prefetchIndex: prefetchIndex,
        orderedIDs: orderedIDs,
        revisionsByID: revisionsByID,
        coverClient: coverClient,
        artworkPrefetcher: artworkPrefetcher)
    }
  #else
    var body: some View {
      harnessTimedSpan("Tile.construct") { tileBody }
    }
  #endif

  private var tileBody: some View {
    let itemPlaybackStatus = finishedStatus.playbackStatus(item.serverItemId)
    let playbackStatus = LibraryBrowsePresentation.rowPlaybackStatus(
      playbackStatus: itemPlaybackStatus)

    return Button {
      selectItem(item)
    } label: {
      harnessTimedSpan("Tile.label") { tileLabel(playbackStatus: playbackStatus) }
        .frame(
          width: tileWidth,
          height: HarnessSwitch.pinnedTileHeight(tileWidth: tileWidth),
          alignment: .topLeading
        )
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .ablatable(HarnessSwitch.skipsTileAccessibility) { $0.accessibilityElement(children: .combine) }
    .libraryBrowseTitleInteractions(
      item: item,
      coverClient: coverClient,
      finishedStatus: finishedStatus,
      playback: playback,
      actions: actions,
      onSelect: selectItem,
      onPresentReader: onPresentReader,
      onSearch: onSearch
    )
    .onAppear {
      guard prefetchesOnAppear else { return }
      artworkPrefetcher.observe(
        visibleIndex: prefetchIndex,
        orderedIDs: orderedIDs,
        displaySize: LibraryBrowseLayoutPresentation.regularCoverMinimumWidth,
        displayScale: displayScale,
        client: coverClient, revisionsByID: revisionsByID)
    }
  }

  private func selectItem(_ item: ItemSummary) {
    if let bookZoomTransition,
      bookZoomTransition.selectBook(
        item, occurrence: "library-title-grid/\(item.serverItemId)",
        artworkRole: .libraryThumbnail, displaySize: WhirrMetric.minimumTouchTarget)
    {
    } else {
      onSelect(item)
    }
  }

  @ViewBuilder
  private func tileLabel(
    playbackStatus: LibraryBrowsePresentation.RowPlaybackStatus?
  ) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      CoverImageView(
        itemID: item.serverItemId,
        title: item.title,
        displaySize: LibraryBrowseLayoutPresentation.regularCoverMinimumWidth,
        client: coverClient,
        source: nil,
        author: item.author,
        role: .homeCard,
        presentation: .fitTransparent,
        fitAlignment: .top,
        artworkMarks: CoverArtworkMarks(
          stateSymbol: playbackStatus?.systemImage,
          mediaKind: HomeViewPresentation.badgeKind(for: item.category)),
        cornerRadius: WhirrSpacing.xSmall,
        revision: item.artworkRevision
      )
      .frame(width: tileWidth, height: tileWidth)
      .ablatable(HarnessSwitch.skipsZoomTransitionSource) {
        $0.bookZoomTransitionSource(
          bookZoomTransition?.source(
            item: item, occurrence: "library-title-grid/\(item.serverItemId)"))
      }

      title

      if let subtitle = LibraryBrowsePresentation.subtitle(for: item) {
        Text(subtitle)
          .font(WhirrTypeToken.subheadline.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: WhirrSpacing.xSmall) {
        if let playbackStatus {
          Text(playbackStatus.label)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
        }
        OfflineBadgeRow(
          itemID: item.serverItemId,
          downloadStatus: downloadStatus,
          isCompact: true)
      }
    }
  }

  @ViewBuilder
  private var title: some View {
    let text = Text(item.title)
      .font(WhirrTypeToken.headline.font)
      .foregroundStyle(WhirrColorToken.textPrimary.color)

    if dynamicTypeSize.isAccessibilitySize {
      text.fixedSize(horizontal: false, vertical: true)
    } else {
      text.lineLimit(2, reservesSpace: true)
    }
  }
}

/// A full-tile series button over the entity's borrowed `coverItemID`.
struct LibrarySeriesGridTile: View {
  let group: LibraryEntityGroup
  let tileWidth: CGFloat
  let prefetchIndex: Int?
  let orderedCoverIDs: [String]
  let revisionsByID: [String: ArtworkRevision]
  let coverClient: any ArtworkServing
  let artworkPrefetcher: DirectionalArtworkPrefetcher
  let onSelect: (LibraryEntityGroup) -> Void
  /// See `LibraryTitleGridTile.prefetchesOnAppear`.
  var prefetchesOnAppear = true

  @Environment(\.displayScale) private var displayScale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    Button {
      onSelect(group)
    } label: {
      tileLabel
        .frame(width: tileWidth, alignment: .topLeading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(LibraryBrowsePresentation.entityAccessibilityLabel(for: group))
    .onAppear {
      guard prefetchesOnAppear, let prefetchIndex, group.coverItemID != nil else { return }
      artworkPrefetcher.observe(
        visibleIndex: prefetchIndex,
        orderedIDs: orderedCoverIDs,
        displaySize: LibraryBrowseLayoutPresentation.regularCoverMinimumWidth,
        displayScale: displayScale,
        client: coverClient, revisionsByID: revisionsByID)
    }
  }

  @ViewBuilder
  private var tileLabel: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      if let coverItemID = group.coverItemID {
        CoverImageView(
          itemID: coverItemID,
          title: group.name,
          displaySize: LibraryBrowseLayoutPresentation.regularCoverMinimumWidth,
          client: coverClient,
          source: nil,
          author: group.primaryAuthorName,
          role: .homeCard,
          presentation: .fitTransparent,
          fitAlignment: .top,
          artworkMarks: CoverArtworkMarks(
            mediaKind: group.categories.first.map { HomeViewPresentation.badgeKind(for: $0) }),
          cornerRadius: WhirrSpacing.xSmall,
          revision: group.coverRevision
        )
        .frame(width: tileWidth, height: tileWidth)
      } else {
        Image(systemName: LibraryBrowsePresentation.entityPlaceholderSymbol(for: group.kind))
          .font(WhirrTypeToken.display.font)
          .foregroundStyle(WhirrColorToken.brandInk.color)
          .frame(width: tileWidth, height: tileWidth)
          .background(
            WhirrColorToken.surfaceSecondary.color,
            in: RoundedRectangle(cornerRadius: WhirrSpacing.small))
      }

      seriesTitle

      if let subtitle = LibraryBrowsePresentation.entitySubtitle(for: group) {
        Text(subtitle)
          .font(WhirrTypeToken.subheadline.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: WhirrSpacing.xxSmall) {
        ForEach(group.categories, id: \.self) { category in
          MediaKindBadgeView(
            kind: HomeViewPresentation.badgeKind(for: category),
            label: HomeRowPresentation.badgeLabel(for: category))
        }
      }
    }
  }

  @ViewBuilder
  private var seriesTitle: some View {
    let text = Text(group.name)
      .font(WhirrTypeToken.headline.font)
      .foregroundStyle(WhirrColorToken.textPrimary.color)

    if dynamicTypeSize.isAccessibilitySize {
      text.fixedSize(horizontal: false, vertical: true)
    } else {
      text.lineLimit(2, reservesSpace: true)
    }
  }
}

/// A full-tile author card. The card's padding is inside `tileWidth`, so the outer width is the
/// resolved column width and the policy's 320-point outer minimum holds.
struct LibraryAuthorGridTile: View {
  let group: LibraryEntityGroup
  let tileWidth: CGFloat
  let coverClient: any ArtworkServing
  let onSelect: (LibraryEntityGroup) -> Void

  var body: some View {
    Button {
      onSelect(group)
    } label: {
      libraryAuthorCardLabel(group: group, coverClient: coverClient)
        .frame(width: contentWidth, alignment: .leading)
        .editorialCardSurface(.neutral)
        .frame(width: tileWidth, alignment: .leading)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(LibraryBrowsePresentation.entityAccessibilityLabel(for: group))
  }

  private var contentWidth: CGFloat {
    max(1, tileWidth - 2 * LibraryBrowseLayoutPresentation.authorCardContentPadding)
  }
}
