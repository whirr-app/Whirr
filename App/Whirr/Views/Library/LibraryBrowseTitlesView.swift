import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

#if PERF_INVESTIGATION
  import QuartzCore
#endif

/// Read-only library browse over `LibraryBrowseModel`. Copy comes from
/// `LibraryBrowseModel.State.copyText(for:)` (it takes the filter, so an empty podcast list isn't
/// an empty shelf of books); this view only switches over the state (the exception
/// ARCHITECTURE.md allows) and renders rows. `LibraryBrowsePresentation` decides which states show
/// copy in the list and which in the navigation bar.
///
/// The `Titles / Authors / Series` picker comes from the root container as the first list row, as
/// Home and Podcasts place their chips; mode and filter are independent controls.
///
/// These are Titles' compact-width rows, not its list: `LibraryBrowseRootView` owns the compact
/// `List` and the regular grid, since browse state must outlive a mode switch.
struct LibraryBrowseTitlesView: View {
  @Bindable var model: LibraryBrowseModel
  let coverClient: any ArtworkServing
  /// Downloaded/offline badges. One screen-wide projection, read synchronously per row rather
  /// than observed per row.
  let downloadStatus: DownloadStatusStore
  /// Screen-wide finished projection behind every row's finished badge. One subscription for the
  /// list, read synchronously per row.
  let finishedStatus: FinishedStatusStore
  /// One screen-scoped model behind every row's long-press menu.
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let query: String
  /// Owned by the root so it survives a mode switch. Cancelled when the whole Library scrolls
  /// away, not when Titles stops being shown.
  let artworkPrefetcher: DirectionalArtworkPrefetcher
  let onSelect: (ItemSummary) -> Void
  /// Opens the reader for an ebook row's long-press Read entry. The ebook counterpart of
  /// `onSelect`'s push, threaded from `LibraryShellView` the same way.
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void
  @Environment(\.editMode) private var editMode
  @Environment(\.displayScale) private var displayScale
  @Environment(\.bookZoomTransitionContext) private var bookZoomTransition

  var body: some View {
    let items = currentItems
    #if PERF_INVESTIGATION
      let rowIndexStart = CACurrentMediaTime()
    #endif
    let indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    // Hoisted out of the row builder: mapping the whole library for every row that appears
    // turns scrolling into O(rows × library) main-actor allocation.
    let orderedIDs = items.map(\.serverItemId)
    let revisionsByID = items.artworkRevisionsByID
    let nowPlaying = playback.nowPlayingIdentity
    #if PERF_INVESTIGATION
      let _ = MicrostutterProbe.shared.note(
        "LibraryTitles.rowIndexTables", count: items.count,
        elapsed: CACurrentMediaTime() - rowIndexStart)
    #endif
    let banner = LibraryBrowsePresentation.banner(for: model.state, filters: model.filters)

    switch LibraryBrowsePresentation.titlesRowsPresentation(
      state: model.state, filters: model.filters, query: query, matchCount: items.count)
    {
    case .none:
      EmptyView()
    case .filteredEmpty:
      filteredEmptyState
        .editorialListRow()
        .selectionDisabled()
    case .queryEmpty(let query, let offersClearFilters):
      queryEmptyState(query: query, offersClearFilters: offersClearFilters)
        .editorialListRow()
        .selectionDisabled()
    case .rows:
      if let banner, banner.isEmpty == false {
        Text(banner)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .padding(WhirrSpacing.small)
          .frame(maxWidth: .infinity, alignment: .leading)
          .editorialListRow()
          .selectionDisabled()
      }

      AlphabeticallyIndexedRows(items: items, title: \.title) { item in
        itemRow(
          item, index: indices[item.id] ?? 0, orderedIDs: orderedIDs, revisionsByID: revisionsByID,
          nowPlaying: nowPlaying
        )
        .tag(item.serverItemId)
        .selectionDisabled(!LibraryBrowsePresentation.isSelectable(item))
      }
    }
  }

  private var currentItems: [ItemSummary] {
    #if PERF_INVESTIGATION
      let started = CACurrentMediaTime()
      defer {
        MicrostutterProbe.shared.note(
          "LibraryTitles.currentItems", elapsed: CACurrentMediaTime() - started)
      }
    #endif
    return model.quickFilteredItems(query: query)
  }

  /// Rendered locally because `EmptyStateView` has no action slot, and this state must carry an
  /// escape hatch.
  private var filteredEmptyState: some View {
    ContentUnavailableView {
      Label(
        model.state.emptyTitle(for: model.filters),
        systemImage: LibraryBrowsePresentation.emptyStateSymbol(for: model.state, filters: model.filters))
    } description: {
      Text(model.state.copyText(for: model.filters))
    } actions: {
      Button(LibraryFilterCopy.clearFiltersLabel) { model.clearFilters() }
        .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
    }
  }

  /// An in-list row, like `filteredEmptyState`: `modeOverlay` drops hit testing and would put
  /// this recovery state under a live keyboard instead of beside the rows it replaces.
  private func queryEmptyState(query: String, offersClearFilters: Bool) -> some View {
    ContentUnavailableView {
      Label(
        LibraryBrowsePresentation.queryEmptyTitle(query: query),
        systemImage: LibraryBrowsePresentation.queryEmptySymbol)
    } description: {
      Text(LibraryBrowsePresentation.queryEmptyMessage)
    } actions: {
      if offersClearFilters {
        Button(LibraryFilterCopy.clearFiltersLabel) { model.clearFilters() }
          .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
      }
    }
    .accessibilityIdentifier(LibraryAccessibilityID.queryEmptyState)
  }

  private func itemRow(
    _ item: ItemSummary, index: Int, orderedIDs: [String],
    revisionsByID: [String: ArtworkRevision], nowPlaying: ListeningIdentity?
  ) -> some View {
    let itemPlaybackStatus = finishedStatus.playbackStatus(item.serverItemId)
    let playbackStatus = LibraryBrowsePresentation.rowPlaybackStatus(
      playbackStatus: itemPlaybackStatus)

    let label = ItemListRow(
      title: item.title,
      author: LibraryBrowsePresentation.subtitle(for: item)
    ) {
      ZStack(alignment: .topTrailing) {
        CoverImageView(
          itemID: item.serverItemId, title: item.title,
          displaySize: WhirrMetric.minimumTouchTarget, client: coverClient, source: nil,
          author: item.author, revision: item.artworkRevision
        )
        .bookZoomTransitionSource(
          bookZoomTransition?.source(item: item, occurrence: "library-title/\(item.serverItemId)"))
        MediaKindBadgeView(
          kind: HomeViewPresentation.badgeKind(for: item.category),
          label: HomeRowPresentation.badgeLabel(for: item.category)
        )
        .padding(WhirrSpacing.xxSmall)
      }
    } progress: {
      HStack(spacing: WhirrSpacing.xSmall) {
        if let playbackStatus {
          LibraryPlaybackStatusBadge(itemID: item.serverItemId, status: playbackStatus)
        }
        OfflineBadgeRow(
          itemID: item.serverItemId, downloadStatus: downloadStatus, isCompact: true)
      }
    }

    // One container, not a `Group`: the row must be a single view whichever shape it takes, or
    // the `List` builds every title to count them.
    return ZStack {
      if editMode?.wrappedValue.isEditing == true {
        label
          .contentShape(Rectangle())
          .accessibilityElement(children: .combine)
      } else {
        Button {
          selectItem(item)
        } label: {
          label
        }
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
      }
    }
    // Compact list rows only; the regular-width cover grid is long-press only, like every grid.
    .itemSwipeActions(
      ItemSwipeSubject(
        itemID: item.serverItemId, episodeID: nil, category: item.category,
        hasReadableEbook: item.hasReadableEbook, playbackStatus: itemPlaybackStatus,
        durationSeconds: item.durationSeconds),
      isSelecting: editMode?.wrappedValue.isEditing == true,
      nowPlaying: nowPlaying,
      playback: playback,
      actions: actions,
      onRead: { onPresentReader(item.serverItemId, item.title, item.category) }
    )
    .onAppear {
      artworkPrefetcher.observe(
        visibleIndex: index,
        orderedIDs: orderedIDs,
        displaySize: WhirrMetric.minimumTouchTarget,
        displayScale: displayScale,
        client: coverClient, revisionsByID: revisionsByID)
    }
  }

  private func selectItem(_ item: ItemSummary) {
    if let bookZoomTransition,
      bookZoomTransition.selectBook(
        item, occurrence: "library-title/\(item.serverItemId)",
        artworkRole: .libraryThumbnail, displaySize: WhirrMetric.minimumTouchTarget)
    {
    } else {
      onSelect(item)
    }
  }
}
