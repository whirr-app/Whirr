import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The filtered values preserve source order for prefetching; the indexed sections feed both the
/// alphabet menu and the regular grid.
private struct LibraryBrowseRegularSections<Value: Identifiable> {
  let values: [Value]
  let indexed: [LibraryBrowsePresentation.Section<Value>]

  var availableSectionIDs: Set<String> {
    Set(indexed.filter { $0.items.isEmpty == false }.map(\.id))
  }
}

private enum LibraryBrowseRegularProjection {
  case titles(LibraryBrowseRegularSections<ItemSummary>)
  case entities(LibraryBrowseRegularSections<LibraryEntityGroup>)

  var availableSectionIDs: Set<String> {
    switch self {
    case .titles(let sections): sections.availableSectionIDs
    case .entities(let sections): sections.availableSectionIDs
    }
  }
}

/// Composition for the regular-width Library branch. The root owns the models and the scroll
/// requests; this view owns only the grid projection, handed to the collection-view host as one
/// snapshot.
struct LibraryBrowseRegularContent<ModePicker: View>: View {
  let mode: LibraryBrowsePresentation.Mode
  @Bindable var browseModel: LibraryBrowseModel
  let authorsModel: AuthorSeriesBrowseModel?
  let seriesModel: AuthorSeriesBrowseModel?
  let query: String
  let coverClient: any ArtworkServing
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let artworkPrefetcher: DirectionalArtworkPrefetcher
  let onSelectTitle: (ItemSummary) -> Void
  let onSelectEntity: (LibraryEntityGroup) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void
  let onJumpToTarget: (String) -> Void
  /// The root's reselect counter and the latest A-Z jump, both executed by the collection view.
  let scrollToTopRequest: Int
  let jumpRequest: LibraryBrowseJumpRequest?
  /// Drives only the SwiftUI grid arm kept for A/B measurement (`HarnessSwitch.usesSwiftUILibraryGrid`).
  @Binding var scrollPosition: ScrollPosition
  let onRefresh: () async -> Void
  let onScrollPhaseChange: (ScrollPhase) -> Void
  private let modePicker: ModePicker

  init(
    mode: LibraryBrowsePresentation.Mode,
    browseModel: LibraryBrowseModel,
    authorsModel: AuthorSeriesBrowseModel?,
    seriesModel: AuthorSeriesBrowseModel?,
    query: String,
    coverClient: any ArtworkServing,
    downloadStatus: DownloadStatusStore,
    finishedStatus: FinishedStatusStore,
    actions: ItemActionsModel,
    playback: PlaybackModel,
    artworkPrefetcher: DirectionalArtworkPrefetcher,
    onSelectTitle: @escaping (ItemSummary) -> Void,
    onSelectEntity: @escaping (LibraryEntityGroup) -> Void,
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void,
    onSearch: @escaping (String) -> Void,
    onJumpToTarget: @escaping (String) -> Void,
    scrollToTopRequest: Int,
    jumpRequest: LibraryBrowseJumpRequest?,
    scrollPosition: Binding<ScrollPosition>,
    onRefresh: @escaping () async -> Void,
    onScrollPhaseChange: @escaping (ScrollPhase) -> Void,
    @ViewBuilder modePicker: () -> ModePicker
  ) {
    self.mode = mode
    self._browseModel = Bindable(browseModel)
    self.authorsModel = authorsModel
    self.seriesModel = seriesModel
    self.query = query
    self.coverClient = coverClient
    self.downloadStatus = downloadStatus
    self.finishedStatus = finishedStatus
    self.actions = actions
    self.playback = playback
    self.artworkPrefetcher = artworkPrefetcher
    self.onSelectTitle = onSelectTitle
    self.onSelectEntity = onSelectEntity
    self.onPresentReader = onPresentReader
    self.onSearch = onSearch
    self.onJumpToTarget = onJumpToTarget
    self.scrollToTopRequest = scrollToTopRequest
    self.jumpRequest = jumpRequest
    self._scrollPosition = scrollPosition
    self.onRefresh = onRefresh
    self.onScrollPhaseChange = onScrollPhaseChange
    self.modePicker = modePicker()
  }

  var body: some View {
    let projection = regularProjection
    let availableSectionIDs = projection.availableSectionIDs

    // Preprocessor-guarded so a release body is the collection host alone: `body` is an implicit
    // `@ViewBuilder`, and an `if` here would make its type `_ConditionalContent` in every build.
    #if DEBUG || PERF_INVESTIGATION
      if HarnessSwitch.usesSwiftUILibraryGrid {
        swiftUIGrid(projection: projection, availableSectionIDs: availableSectionIDs)
      } else {
        collectionHost(projection: projection, availableSectionIDs: availableSectionIDs)
      }
    #else
      collectionHost(projection: projection, availableSectionIDs: availableSectionIDs)
    #endif
  }

  private var entityModel: AuthorSeriesBrowseModel? {
    switch mode {
    case .titles, .collections: nil
    case .authors: authorsModel
    case .series: seriesModel
    }
  }

  private func controlsRow(availableSectionIDs: Set<String>) -> some View {
    HStack(alignment: .center, spacing: WhirrSpacing.small) {
      modePicker
      Spacer(minLength: WhirrSpacing.small)
      LibraryBrowseAlphabetJumpMenu(
        availableSectionIDs: availableSectionIDs,
        isQueryEffective: LibraryQuickFilter.isEffective(query),
        onSelect: { jumpToSection($0, availableSectionIDs: availableSectionIDs) })
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Collection-view host

  private func collectionHost(
    projection: LibraryBrowseRegularProjection, availableSectionIDs: Set<String>
  ) -> some View {
    let rows = rowsPresentation(for: projection)
    return LibraryBrowseCollectionView(
      snapshot: collectionSnapshot(for: projection, rows: rows),
      tileContext: LibraryBrowseCollectionTileContext(
        coverClient: coverClient,
        downloadStatus: downloadStatus,
        finishedStatus: finishedStatus,
        actions: actions,
        playback: playback,
        artworkPrefetcher: artworkPrefetcher,
        onSelectTitle: onSelectTitle,
        onSelectEntity: onSelectEntity,
        onPresentReader: onPresentReader,
        onSearch: onSearch,
        onLoadMore: { [entityModel] in
          guard let entityModel else { return }
          Task { await entityModel.loadMore() }
        }),
      scrollToTopRequest: scrollToTopRequest,
      jumpRequest: jumpRequest,
      onRefresh: onRefresh,
      onScrollPhaseChange: onScrollPhaseChange
    ) {
      controlsRow(availableSectionIDs: availableSectionIDs)
    } stateContent: {
      stateContent(for: rows)
    }
    // Full-bleed so the collection view sits under the bars and insets itself, as a scroll view
    // beneath a navigation bar must for the large title and the search drawer to track it.
    .ignoresSafeArea()
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
  }

  private func rowsPresentation(
    for projection: LibraryBrowseRegularProjection
  ) -> LibraryBrowsePresentation.RowsPresentation {
    switch projection {
    case .titles(let sections):
      return LibraryBrowsePresentation.titlesRowsPresentation(
        state: browseModel.state,
        filters: browseModel.filters,
        query: query,
        matchCount: sections.values.count)
    case .entities(let sections):
      guard let entityModel else { return .none }
      return LibraryBrowsePresentation.entityRowsPresentation(
        state: entityModel.state,
        filters: entityModel.filters,
        hasMore: entityModel.hasMore,
        query: query,
        matchCount: sections.values.count)
    }
  }

  private func collectionSnapshot(
    for projection: LibraryBrowseRegularProjection,
    rows: LibraryBrowsePresentation.RowsPresentation
  ) -> LibraryBrowseCollectionSnapshot {
    switch projection {
    case .titles(let sections):
      return .titles(
        rows: rows,
        banner: LibraryBrowsePresentation.banner(
          for: browseModel.state, filters: browseModel.filters),
        values: sections.values,
        sections: sections.indexed)
    case .entities(let sections):
      return .entities(
        mode: mode,
        rows: rows,
        hasMore: entityModel?.hasMore ?? false,
        values: sections.values,
        sections: sections.indexed)
    }
  }

  @ViewBuilder
  private func stateContent(for rows: LibraryBrowsePresentation.RowsPresentation) -> some View {
    switch rows {
    case .filteredEmpty:
      if let entityModel {
        LibraryBrowseRegularEntitiesFilteredEmptyState(
          kind: entityModel.kind, onClearFilters: browseModel.clearFilters)
      } else {
        LibraryBrowseRegularTitlesFilteredEmptyState(model: browseModel)
      }
    case .queryEmpty(let query, let offersClearFilters):
      LibraryBrowseRegularQueryEmptyState(
        query: query,
        offersClearFilters: offersClearFilters,
        onClearFilters: browseModel.clearFilters)
    case .rows, .none:
      EmptyView()
    }
  }

  // MARK: SwiftUI grid (A/B arm)

  #if DEBUG || PERF_INVESTIGATION
    private func swiftUIGrid(
      projection: LibraryBrowseRegularProjection, availableSectionIDs: Set<String>
    ) -> some View {
      LibraryBrowseRegularContainer(
        scrollPosition: $scrollPosition,
        onRefresh: onRefresh,
        onScrollPhaseChange: onScrollPhaseChange
      ) { availableWidth in
        controlsRow(availableSectionIDs: availableSectionIDs)
          .padding(.bottom, WhirrSpacing.small)

        regularModeRows(availableWidth: availableWidth, projection: projection)
          .transition(.opacity)
      }
    }
  #endif

  /// The sole regular-width filter/index derivation for the selected mode. Both the menu and the
  /// renderer consume this projection below.
  private var regularProjection: LibraryBrowseRegularProjection {
    switch mode {
    case .titles:
      let values = browseModel.quickFilteredItems(query: query)
      return .titles(
        LibraryBrowseRegularSections(
          values: values, indexed: LibraryBrowsePresentation.indexedSections(for: values)))
    case .collections:
      // Not reached: Collections renders through the compact list at every width.
      return .entities(LibraryBrowseRegularSections<LibraryEntityGroup>(values: [], indexed: []))
    case .authors, .series:
      let model = mode == .authors ? authorsModel : seriesModel
      guard let model else {
        return .entities(
          LibraryBrowseRegularSections<LibraryEntityGroup>(values: [], indexed: []))
      }
      let values = LibraryQuickFilter.filter(groups: model.groups, query: query)
      return .entities(
        LibraryBrowseRegularSections(
          values: values,
          indexed: LibraryBrowsePresentation.indexedSections(for: values, title: \.name)))
    }
  }

  #if DEBUG || PERF_INVESTIGATION
    @ViewBuilder
    private func regularModeRows(
      availableWidth: CGFloat?, projection: LibraryBrowseRegularProjection
    ) -> some View {
      switch mode {
      case .titles:
        if case .titles(let sections) = projection {
          LibraryBrowseRegularTitles(
            mode: mode,
            model: browseModel,
            items: sections.values,
            sections: sections.indexed,
            availableWidth: availableWidth,
            coverClient: coverClient,
            downloadStatus: downloadStatus,
            finishedStatus: finishedStatus,
            actions: actions,
            playback: playback,
            artworkPrefetcher: artworkPrefetcher,
            onSelect: onSelectTitle,
            onPresentReader: onPresentReader,
            onSearch: onSearch,
            query: query)
        }
      case .authors:
        if let authorsModel, case .entities(let sections) = projection {
          LibraryBrowseRegularEntities(
            mode: mode,
            model: authorsModel,
            groups: sections.values,
            sections: sections.indexed,
            availableWidth: availableWidth,
            coverClient: coverClient,
            artworkPrefetcher: artworkPrefetcher,
            onSelect: onSelectEntity,
            onClearFilters: browseModel.clearFilters,
            query: query)
        }
      case .series:
        if let seriesModel, case .entities(let sections) = projection {
          LibraryBrowseRegularEntities(
            mode: mode,
            model: seriesModel,
            groups: sections.values,
            sections: sections.indexed,
            availableWidth: availableWidth,
            coverClient: coverClient,
            artworkPrefetcher: artworkPrefetcher,
            onSelect: onSelectEntity,
            onClearFilters: browseModel.clearFilters,
            query: query)
        }
      case .collections:
        EmptyView()
      }
    }
  #endif

  private func jumpToSection(_ sectionID: String, availableSectionIDs: Set<String>) {
    guard
      let targetID = LibraryBrowseLayoutPresentation.sectionTargetID(
        for: sectionID, in: mode, hasItems: availableSectionIDs.contains(sectionID))
    else { return }
    onJumpToTarget(targetID)
  }
}

// The SwiftUI grid's row composition, kept only for the A/B arm and retired with it.
#if DEBUG || PERF_INVESTIGATION
  private struct LibraryBrowseRegularTitles: View {
    let mode: LibraryBrowsePresentation.Mode
    @Bindable var model: LibraryBrowseModel
    let items: [ItemSummary]
    let sections: [LibraryBrowsePresentation.Section<ItemSummary>]
    let availableWidth: CGFloat?
    let coverClient: any ArtworkServing
    let downloadStatus: DownloadStatusStore
    let finishedStatus: FinishedStatusStore
    let actions: ItemActionsModel
    let playback: PlaybackModel
    let artworkPrefetcher: DirectionalArtworkPrefetcher
    let onSelect: (ItemSummary) -> Void
    let onPresentReader: (String, String, ItemMediaCategory) -> Void
    let onSearch: (String) -> Void
    let query: String

    var body: some View {
      switch LibraryBrowsePresentation.titlesRowsPresentation(
        state: model.state,
        filters: model.filters,
        query: query,
        matchCount: items.count
      ) {
      case .none:
        EmptyView()
      case .filteredEmpty:
        titleFilteredEmptyState
      case .queryEmpty(let query, let offersClearFilters):
        LibraryBrowseRegularQueryEmptyState(
          query: query,
          offersClearFilters: offersClearFilters,
          onClearFilters: model.clearFilters)
      case .rows:
        if let banner = LibraryBrowsePresentation.banner(for: model.state, filters: model.filters),
          banner.isEmpty == false
        {
          Text(banner)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WhirrSpacing.small)
        }

        let orderedIDs = items.map(\.serverItemId)
        let revisionsByID = items.artworkRevisionsByID
        let prefetchIndices = Dictionary(
          items.enumerated().map { ($0.element.serverItemId, $0.offset) },
          uniquingKeysWith: { first, _ in first })

        ForEach(sections.filter { $0.items.isEmpty == false }) { section in
          LibraryBrowseRegularSection(sectionID: section.id, mode: mode) {
            LibraryTitleGrid(
              items: section.items,
              availableWidth: availableWidth,
              orderedIDs: orderedIDs,
              revisionsByID: revisionsByID,
              prefetchIndices: prefetchIndices,
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
    }

    private var titleFilteredEmptyState: some View {
      LibraryBrowseRegularTitlesFilteredEmptyState(model: model)
    }
  }

  private struct LibraryBrowseRegularEntities: View {
    let mode: LibraryBrowsePresentation.Mode
    @Bindable var model: AuthorSeriesBrowseModel
    let groups: [LibraryEntityGroup]
    let sections: [LibraryBrowsePresentation.Section<LibraryEntityGroup>]
    let availableWidth: CGFloat?
    let coverClient: any ArtworkServing
    let artworkPrefetcher: DirectionalArtworkPrefetcher
    let onSelect: (LibraryEntityGroup) -> Void
    let onClearFilters: () -> Void
    let query: String

    var body: some View {
      switch LibraryBrowsePresentation.entityRowsPresentation(
        state: model.state,
        filters: model.filters,
        hasMore: model.hasMore,
        query: query,
        matchCount: groups.count
      ) {
      case .none:
        EmptyView()
      case .filteredEmpty:
        entityFilteredEmptyState
      case .queryEmpty(let query, let offersClearFilters):
        LibraryBrowseRegularQueryEmptyState(
          query: query,
          offersClearFilters: offersClearFilters,
          onClearFilters: onClearFilters)
      case .rows:
        if model.kind == .series {
          let orderedCoverIDs = groups.compactMap(\.coverItemID)
          let revisionsByID = groups.coverRevisionsByID
          let prefetchIndices = Dictionary(
            orderedCoverIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first })

          ForEach(sections.filter { $0.items.isEmpty == false }) { section in
            LibraryBrowseRegularSection(sectionID: section.id, mode: mode) {
              LibrarySeriesGrid(
                groups: section.items,
                availableWidth: availableWidth,
                orderedCoverIDs: orderedCoverIDs,
                revisionsByID: revisionsByID,
                prefetchIndices: prefetchIndices,
                coverClient: coverClient,
                artworkPrefetcher: artworkPrefetcher,
                onSelect: onSelect)
            }
          }
        } else {
          ForEach(sections.filter { $0.items.isEmpty == false }) { section in
            LibraryBrowseRegularSection(sectionID: section.id, mode: mode) {
              LibraryAuthorGrid(
                groups: section.items,
                availableWidth: availableWidth,
                coverClient: coverClient,
                onSelect: onSelect)
            }
          }
        }

        if model.hasMore {
          ProgressView()
            .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
            .accessibilityLabel(
              "Loading more \(AuthorSeriesBrowseCopy.entityNoun(for: model.kind))"
            )
            .onAppear { Task { await model.loadMore() } }
        }
      }
    }

    private var entityFilteredEmptyState: some View {
      LibraryBrowseRegularEntitiesFilteredEmptyState(kind: model.kind, onClearFilters: onClearFilters)
    }
  }

#endif

private struct LibraryBrowseRegularTitlesFilteredEmptyState: View {
  @Bindable var model: LibraryBrowseModel

  var body: some View {
    ContentUnavailableView {
      Label(
        model.state.emptyTitle(for: model.filters),
        systemImage: LibraryBrowsePresentation.emptyStateSymbol(
          for: model.state, filters: model.filters))
    } description: {
      Text(model.state.copyText(for: model.filters))
    } actions: {
      Button(LibraryFilterCopy.clearFiltersLabel) { model.clearFilters() }
        .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
    }
  }
}

private struct LibraryBrowseRegularEntitiesFilteredEmptyState: View {
  let kind: SearchResultKind
  let onClearFilters: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(
        kind == .author ? "No Matching Authors" : "No Matching Series",
        systemImage: FilterButtonPresentation.emptyStateSymbolName)
    } description: {
      Text(
        "No \(AuthorSeriesBrowseCopy.entityNoun(for: kind)) have anything matching your filters.")
    } actions: {
      Button(LibraryFilterCopy.clearFiltersLabel) { onClearFilters() }
        .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
    }
  }
}

private struct LibraryBrowseRegularQueryEmptyState: View {
  let query: String
  let offersClearFilters: Bool
  let onClearFilters: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label(
        LibraryBrowsePresentation.queryEmptyTitle(query: query),
        systemImage: LibraryBrowsePresentation.queryEmptySymbol)
    } description: {
      Text(LibraryBrowsePresentation.queryEmptyMessage)
    } actions: {
      if offersClearFilters {
        Button(LibraryFilterCopy.clearFiltersLabel) { onClearFilters() }
          .accessibilityIdentifier(LibraryAccessibilityID.clearFiltersButton)
      }
    }
    .accessibilityIdentifier(LibraryAccessibilityID.queryEmptyState)
  }
}
