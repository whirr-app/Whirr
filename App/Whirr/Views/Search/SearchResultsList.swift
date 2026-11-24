import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// The sectioned results list for a settled, non-empty `SearchModel.State.results`. Section,
/// match-reason, glyph and routing logic lives in `SearchViewPresentation`; this view only lays
/// rows out and wires taps through to the callers `SearchView` exposes.
struct SearchResultsList: View {
  let sections: [SearchSection]
  let banner: String?
  let coverClient: any ArtworkServing
  /// Read synchronously per row, never a per-row observation.
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  /// `parentItemID -> show title`, resolved by `SearchView` via `LibraryReading`. A plain value
  /// so `SearchViewPresentation.episodeShowName` stays a pure, testable function.
  let showTitles: [String: String]
  /// Sections with a `loadMore(section:)` call in flight. Owned by `SearchView`, since
  /// `SearchModel.loadMore` exposes no loading flag.
  let loadingSections: Set<SearchResultKind>
  let onSelectItem: (ItemSummary, BookZoomTransitionSource?) -> Void
  let onSelectRoute: (NavigationModel.Route) -> Void
  /// An episode result opens the episode card; `selectItem(_:)` falls back to `onSelectItem`'s
  /// show push only when a ref can't be built from the row
  /// (`SearchViewPresentation.episodeRef(for:)`).
  let onSelectEpisode: (String, String) -> Void
  /// Opens the reader for an ebook row's long-press Read entry. Threaded from `LibraryShellView`
  /// like `onSelect`.
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void
  /// Pages the next batch for one section. `SearchView` wraps it with its `loadingSections`
  /// bookkeeping.
  let onLoadMore: (SearchResultKind) async -> Void

  /// The card's inner padding, owned by the row rather than the chrome: padding applied by the
  /// card modifier sits outside the row's button, so it becomes a dead ring inside the card's edge
  /// instead of part of the tap target. Same contract as `PodcastEpisodeCardRow`.
  static var cardContentPadding: CGFloat { EditorialCardSurfaceModifier.contentPadding }

  /// What the card modifier adds on top: nothing, because the row applies it above.
  static var chromeContentPadding: CGFloat { 0 }

  @Environment(\.displayScale) private var displayScale
  @Environment(\.bookZoomTransitionContext) private var bookZoomTransition
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var artworkPrefetcher = DirectionalArtworkPrefetcher()
  @State private var availableWidth: CGFloat = 0

  private var pageInset: CGFloat {
    SearchViewPresentation.pageInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  var body: some View {
    // Computed once per render, not rebuilt inside a row's `onAppear`. Flattened across every
    // section so the prefetcher's ahead/behind window stays correct past the first section.
    let orderedSections = SearchViewPresentation.orderedSections(sections)
    let coverIDs = SearchViewPresentation.flattenedCoverItemIDs(orderedSections)
    let coverIndexByRowID = SearchViewPresentation.coverIndexByRowID(orderedSections)
    let coverRevisionsByID = SearchViewPresentation.coverRevisionsByID(orderedSections)
    let nowPlaying = playback.nowPlayingIdentity

    return VStack(spacing: 0) {
      if let banner, banner.isEmpty == false {
        Text(banner)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .editorialCardSurface(.neutral)
          .padding(.horizontal, pageInset)
          .padding(.vertical, WhirrSpacing.xSmall)
      }
      List {
        ForEach(orderedSections) { section in
          Section {
            ForEach(section.rows) { row in
              rowView(
                row, coverIDs: coverIDs, coverIndexByRowID: coverIndexByRowID,
                coverRevisionsByID: coverRevisionsByID, nowPlaying: nowPlaying)
            }
            if SearchViewPresentation.showsLoadMore(for: section) {
              loadMoreRow(for: section.kind)
            }
          } header: {
            BrowseSectionHeaderView(title: SearchCopy.sectionTitle(for: section.kind))
              .padding(.horizontal, pageInset)
              .padding(.top, WhirrSpacing.medium)
              .padding(.bottom, WhirrSpacing.xSmall)
              .textCase(nil)
          }
        }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
      .primaryScrollEdgeEffect()
      .scrollDismissesKeyboard(
        SearchViewPresentation.resultsScrollDismissal
      )
      .onDisappear { artworkPrefetcher.cancel() }
    }
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.width
    } action: { width in
      availableWidth = width
    }
  }

  @ViewBuilder
  private func rowView(
    _ row: SearchResultRow, coverIDs: [String], coverIndexByRowID: [String: Int],
    coverRevisionsByID: [String: ArtworkRevision], nowPlaying: ListeningIdentity?
  ) -> some View {
    switch row.kind {
    case .book, .podcast, .episode:
      itemRow(
        row, coverIDs: coverIDs, coverIndexByRowID: coverIndexByRowID,
        coverRevisionsByID: coverRevisionsByID, nowPlaying: nowPlaying)
    case .author, .series:
      entityRow(row)
    }
  }

  private func itemRow(
    _ row: SearchResultRow, coverIDs: [String], coverIndexByRowID: [String: Int],
    coverRevisionsByID: [String: ArtworkRevision], nowPlaying: ListeningIdentity?
  ) -> some View {
    let subtitleText =
      row.kind == .episode
      ? SearchViewPresentation.episodeShowName(for: row, showTitles: showTitles)
      : SearchViewPresentation.itemSubtitle(for: row)
    let coverID = SearchViewPresentation.coverItemID(for: row)
    let menu = SearchViewPresentation.contextMenu(for: row)
    let bookSource: BookZoomTransitionSource? =
      if row.kind == .book, let summary = SearchViewPresentation.itemSummary(for: row) {
        bookZoomTransition?.source(item: summary, occurrence: "search/\(row.id)")
      } else {
        nil
      }

    return Button {
      selectItem(row)
    } label: {
      ItemListRow(
        title: row.title, author: subtitleText
      ) {
        ZStack(alignment: .topTrailing) {
          if let coverID {
            CoverImageView(
              itemID: coverID, title: row.title, displaySize: WhirrMetric.minimumTouchTarget,
              client: coverClient, source: nil, revision: row.artworkRevision
            )
            .bookZoomTransitionSource(bookSource)
          }
          if let badge = SearchViewPresentation.mediaBadge(for: row) {
            MediaKindBadgeView(kind: badge.kind, label: badge.label)
              .padding(WhirrSpacing.xxSmall)
          } else {
            Image(systemName: SearchViewPresentation.symbolName(for: row))
              .font(WhirrTypeToken.caption.font)
              .padding(WhirrSpacing.xxSmall)
              .badgeBackground(in: Circle())
              .padding(WhirrSpacing.xxSmall)
          }
        }
      } progress: {
        // Item-level rows only. Episode-scoped rows are excluded, matching
        // `DefaultSearchReading`'s downloadedOnly predicate.
        if row.kind == .episode {
          EmptyView()
        } else {
          OfflineBadgeRow(itemID: row.entityID, downloadStatus: downloadStatus, isCompact: true)
        }
      }
      // The card's padding sits inside the label so it is part of the tap shape, not a dead ring.
      // `.buttonStyle(.plain)` hit-tests drawn content, not the frame, so the shape is set
      // explicitly. `editorialCardListRow` passes `contentPadding: 0` to match.
      .padding(Self.cardContentPadding)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .modifier(
      SearchItemContextMenuModifier(
        row: row, menu: menu, coverClient: coverClient, finishedStatus: finishedStatus,
        playback: playback, actions: actions,
        onSelectItem: { self.selectItem(row) }, onPresentReader: onPresentReader,
        onSearch: onSearch)
    )
    // Same identity and playback status as the context menu.
    .itemSwipeActions(
      menu.map { menu in
        ItemSwipeSubject(
          itemID: menu.itemID, episodeID: menu.episodeID, category: menu.category,
          hasReadableEbook: menu.hasReadableEbook,
          playbackStatus: finishedStatus.playbackStatus(itemID: menu.itemID, episodeID: menu.episodeID),
          durationSeconds: nil)
      },
      isSelecting: false,
      nowPlaying: nowPlaying,
      playback: playback,
      actions: actions,
      onRead: menu.map { menu in { onPresentReader(menu.itemID, row.title, menu.category) } }
    )
    .editorialCardListRow(
      .neutral, contentPadding: Self.chromeContentPadding, horizontalInset: pageInset
    )
    .listRowSeparator(.hidden)
    // VoiceOver reads the title and match reason/author as one utterance, not two separate rows.
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text("\(row.title), \(subtitleText)"))
    .onAppear {
      guard coverID != nil, let index = coverIndexByRowID[row.id] else { return }
      artworkPrefetcher.observe(
        visibleIndex: index, orderedIDs: coverIDs, displaySize: WhirrMetric.minimumTouchTarget,
        displayScale: displayScale, client: coverClient, revisionsByID: coverRevisionsByID)
    }
  }

  private func entityRow(_ row: SearchResultRow) -> some View {
    Button {
      guard let route = SearchViewPresentation.route(for: row) else { return }
      onSelectRoute(route)
    } label: {
      ItemListRow(title: row.title, author: SearchViewPresentation.entitySubtitle(for: row)) {
        Image(systemName: SearchViewPresentation.symbolName(for: row))
          .font(WhirrTypeToken.title.font)
          .frame(width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget)
          .badgeBackground(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      } progress: {
        EmptyView()
      }
      .padding(Self.cardContentPadding)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .editorialCardListRow(
      .neutral, contentPadding: Self.chromeContentPadding, horizontalInset: pageInset
    )
    .listRowSeparator(.hidden)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      Text("\(row.title), \(SearchViewPresentation.entitySubtitle(for: row))"))
  }

  private func selectItem(_ row: SearchResultRow) {
    // An episode result opens the episode card when the row identifies both its show and itself.
    // Rows that can't fall back to the show push (`itemSummary(for:)`).
    if let ref = SearchViewPresentation.episodeRef(for: row) {
      onSelectEpisode(ref.itemID, ref.episodeID)
      return
    }
    guard let summary = SearchViewPresentation.itemSummary(for: row) else { return }
    onSelectItem(summary, bookZoomTransition?.source(item: summary, occurrence: "search/\(row.id)"))
  }

  /// Per-section load-more control, disabled and showing a `ProgressView` while its page request
  /// is in flight. The caller gates it on `SearchViewPresentation.showsLoadMore`.
  @ViewBuilder
  private func loadMoreRow(for kind: SearchResultKind) -> some View {
    let isLoading = SearchViewPresentation.isLoadingMore(section: kind, loadingSections: loadingSections)
    Button {
      Task { await onLoadMore(kind) }
    } label: {
      HStack {
        Spacer()
        if isLoading {
          ProgressView()
        } else {
          Text(SearchCopy.loadMoreButtonTitle)
            .font(WhirrTypeToken.subheadline.font)
        }
        Spacer()
      }
      .frame(minHeight: WhirrMetric.minimumTouchTarget)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .listRowInsets(
      EdgeInsets(
        top: WhirrSpacing.xSmall,
        leading: pageInset,
        bottom: WhirrSpacing.xSmall,
        trailing: pageInset)
    )
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .disabled(isLoading)
  }
}

/// Shared by search and author/series item rows so the `.itemContextMenu` call site, which needs
/// every field the modifier takes, doesn't force either row closure to spell them all inline.
struct SearchItemContextMenuModifier: ViewModifier {
  let row: SearchResultRow
  let menu:
    (
      itemID: String,
      episodeID: String?,
      category: ItemMediaCategory,
      hasReadableEbook: Bool
    )?
  let coverClient: any ArtworkServing
  let finishedStatus: FinishedStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelectItem: () -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void

  func body(content: Content) -> some View {
    if let menu {
      content.itemContextMenu(
        ItemMenuSubject(
          itemID: menu.itemID,
          title: row.title,
          author: row.subtitle,
          duration: nil,
          category: menu.category,
          hasReadableEbook: menu.hasReadableEbook,
          episodeID: menu.episodeID,
          playbackStatus: {
            finishedStatus.playbackStatus(itemID: menu.itemID, episodeID: menu.episodeID)
          },
          showsNarratorLink: false,
          narrator: nil,
          coverClient: coverClient,
          revision: row.artworkRevision,
          playback: playback,
          actions: actions),
        placement: .searchResultRow,
        onOpen: onSelectItem,
        onRead: { onPresentReader(menu.itemID, row.title, menu.category) },
        onSearch: onSearch)
    } else {
      content
    }
  }
}
