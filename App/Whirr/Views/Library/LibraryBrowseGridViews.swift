import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The regular-width Library scroll surface. Width is measured from this view's local content
/// geometry after its explicit page insets, so Split View panes do not inherit a device-wide width.
///
/// Scroll behaviour attaches to the `ScrollView` declared here, not above: the mode picker's chip
/// rail is a horizontal `ScrollView` inside, so an ancestor modifier would let the rail drive
/// `onScrollPhaseChange` (and the presentation deferral) and share the A-Z jump's position binding.
struct LibraryBrowseRegularContainer<Content: View>: View {
  @Binding var scrollPosition: ScrollPosition
  let onRefresh: () async -> Void
  let onScrollPhaseChange: (ScrollPhase) -> Void
  private let content: (CGFloat?) -> Content
  @State private var availableWidth: CGFloat?

  init(
    scrollPosition: Binding<ScrollPosition>,
    onRefresh: @escaping () async -> Void,
    onScrollPhaseChange: @escaping (ScrollPhase) -> Void,
    @ViewBuilder content: @escaping (CGFloat?) -> Content
  ) {
    self._scrollPosition = scrollPosition
    self.onRefresh = onRefresh
    self.onScrollPhaseChange = onScrollPhaseChange
    self.content = content
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: WhirrSpacing.small) {
        content(availableWidth)
      }
      .scrollTargetLayout()
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, WhirrSpacing.medium)
      .padding(.vertical, WhirrSpacing.small)
      .onGeometryChange(for: CGFloat.self) {
        max(0, $0.size.width - 2 * WhirrSpacing.medium)
      } action: {
        availableWidth = $0
      }
    }
    .scrollPosition($scrollPosition)
    .refreshable { await onRefresh() }
    .onScrollPhaseChange { _, phase in
      onScrollPhaseChange(phase)
    }
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .primaryScrollEdgeEffect()
  }
}

/// A regular-width alphabet section owns the stable scroll target that the jump menu selects.
/// Empty alphabet sections are omitted from the scroll content; the menu still receives them and
/// disables their entries.
struct LibraryBrowseRegularSection<Content: View>: View {
  let sectionID: String
  /// Part of the scroll target: every mode's sections share one lazy container, so the mode keeps
  /// a letter in Titles distinct from that letter in Authors.
  let mode: LibraryBrowsePresentation.Mode
  private let content: Content

  init(
    sectionID: String,
    mode: LibraryBrowsePresentation.Mode,
    @ViewBuilder content: () -> Content
  ) {
    self.sectionID = sectionID
    self.mode = mode
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      Text(sectionID)
        .font(WhirrTypeToken.caption.font.weight(.semibold))
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .accessibilityAddTraits(.isHeader)

      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .id(targetID)
  }

  private var targetID: String {
    LibraryBrowseLayoutPresentation.sectionTargetID(for: sectionID, in: mode, hasItems: true)
      ?? sectionID
  }
}

/// One alphabet section of regular title tiles. The caller supplies the global ordering so the
/// screen-scoped directional prefetcher keeps its window correct across section boundaries.
struct LibraryTitleGrid: View {
  let items: [ItemSummary]
  let availableWidth: CGFloat?
  let orderedIDs: [String]
  let revisionsByID: [String: ArtworkRevision]
  let prefetchIndices: [String: Int]
  let coverClient: any ArtworkServing
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let artworkPrefetcher: DirectionalArtworkPrefetcher
  let onSelect: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void

  @Environment(\.displayScale) private var displayScale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    LazyVGrid(
      columns: columns,
      alignment: .leading,
      spacing: LibraryBrowseLayoutPresentation.gridSpacing
    ) {
      ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
        LibraryTitleGridTile(
          item: item,
          tileWidth: tileWidth,
          prefetchIndex: DirectionalArtworkPrefetcher.rowAlignedIndex(
            prefetchIndices[item.serverItemId] ?? offset, columns: columnCount),
          orderedIDs: orderedIDs,
          revisionsByID: revisionsByID,
          coverClient: coverClient,
          downloadStatus: downloadStatus,
          finishedStatus: finishedStatus,
          actions: actions,
          playback: playback,
          artworkPrefetcher: artworkPrefetcher,
          onSelect: onSelect,
          onPresentReader: onPresentReader,
          onSearch: onSearch)
      }
    }
  }

  private var layout: AdaptiveListLayout {
    LibraryBrowseLayoutPresentation.resolve(
      for: .titles,
      horizontalSizeClass: .regular,
      availableWidth: availableWidth,
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  private var columnCount: Int {
    if case .grid(let count) = layout { return count }
    return 1
  }

  private var tileWidth: CGFloat {
    guard let availableWidth, availableWidth.isFinite, availableWidth > 0 else {
      return LibraryBrowseLayoutPresentation.minimumTileWidth(
        for: .titles, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }
    return LibraryBrowseLayoutPresentation.tileWidth(
      forAvailableWidth: availableWidth, columns: columnCount)
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(
        .fixed(tileWidth),
        spacing: LibraryBrowseLayoutPresentation.gridSpacing,
        alignment: .top),
      count: columnCount)
  }
}

/// One alphabet section of regular author cards. The card's 320-point outer minimum belongs to
/// the policy; this renderer only turns its resolved column width into a fixed grid.
struct LibraryAuthorGrid: View {
  let groups: [LibraryEntityGroup]
  let availableWidth: CGFloat?
  let coverClient: any ArtworkServing
  let onSelect: (LibraryEntityGroup) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    LazyVGrid(
      columns: columns,
      alignment: .leading,
      spacing: LibraryBrowseLayoutPresentation.gridSpacing
    ) {
      ForEach(groups) { group in
        LibraryAuthorGridTile(
          group: group, tileWidth: tileWidth, coverClient: coverClient, onSelect: onSelect)
      }
    }
  }

  private var layout: AdaptiveListLayout {
    LibraryBrowseLayoutPresentation.resolve(
      for: .authors,
      horizontalSizeClass: .regular,
      availableWidth: availableWidth,
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  private var columnCount: Int {
    if case .grid(let count) = layout { return count }
    return 1
  }

  private var tileWidth: CGFloat {
    guard let availableWidth, availableWidth.isFinite, availableWidth > 0 else {
      return LibraryBrowseLayoutPresentation.minimumTileWidth(
        for: .authors, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }
    return LibraryBrowseLayoutPresentation.tileWidth(
      forAvailableWidth: availableWidth, columns: columnCount)
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(
        .fixed(tileWidth),
        spacing: LibraryBrowseLayoutPresentation.gridSpacing,
        alignment: .top),
      count: columnCount)
  }
}

/// One alphabet section of regular series cards. A series borrows the entity's existing
/// `coverItemID`; it does not invent a second projection or a new artwork identity.
struct LibrarySeriesGrid: View {
  let groups: [LibraryEntityGroup]
  let availableWidth: CGFloat?
  let orderedCoverIDs: [String]
  let revisionsByID: [String: ArtworkRevision]
  let prefetchIndices: [String: Int]
  let coverClient: any ArtworkServing
  let artworkPrefetcher: DirectionalArtworkPrefetcher
  let onSelect: (LibraryEntityGroup) -> Void

  @Environment(\.displayScale) private var displayScale
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    LazyVGrid(
      columns: columns,
      alignment: .leading,
      spacing: LibraryBrowseLayoutPresentation.gridSpacing
    ) {
      ForEach(groups) { group in
        LibrarySeriesGridTile(
          group: group,
          tileWidth: tileWidth,
          prefetchIndex: group.coverItemID.flatMap { prefetchIndices[$0] }.map {
            DirectionalArtworkPrefetcher.rowAlignedIndex($0, columns: columnCount)
          },
          orderedCoverIDs: orderedCoverIDs,
          revisionsByID: revisionsByID,
          coverClient: coverClient,
          artworkPrefetcher: artworkPrefetcher,
          onSelect: onSelect)
      }
    }
  }

  private var layout: AdaptiveListLayout {
    LibraryBrowseLayoutPresentation.resolve(
      for: .series,
      horizontalSizeClass: .regular,
      availableWidth: availableWidth,
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  private var columnCount: Int {
    if case .grid(let count) = layout { return count }
    return 1
  }

  private var tileWidth: CGFloat {
    guard let availableWidth, availableWidth.isFinite, availableWidth > 0 else {
      return LibraryBrowseLayoutPresentation.minimumTileWidth(
        for: .series, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    }
    return LibraryBrowseLayoutPresentation.tileWidth(
      forAvailableWidth: availableWidth, columns: columnCount)
  }

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(
        .fixed(tileWidth),
        spacing: LibraryBrowseLayoutPresentation.gridSpacing,
        alignment: .top),
      count: columnCount)
  }
}
