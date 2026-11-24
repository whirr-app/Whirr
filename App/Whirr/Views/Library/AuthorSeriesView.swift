import ABSApi
import AppModel
import DesignSystem
import Foundation
import Observation
import Persistence
import SwiftUI

/// The source item that gives a card its colour is stateful screen data, not a value to derive
/// while SwiftUI is evaluating `body`. Keeping this map in an observable owner lets pagination and
/// inherited filters reconcile it without mutating view state during rendering.
@MainActor @Observable
final class AuthorSeriesWashSourceStore {
  private(set) var sourceItemIDs: [String: String] = [:]

  /// Returns the retained source while it is still visible. The candidate fallback keeps a newly
  /// materialized card filled before the first reconciliation task runs; it does not write state.
  func sourceItemID(for section: AuthorSeriesSection) -> String? {
    guard section.rows.isEmpty == false else { return nil }
    if let selected = sourceItemIDs[section.id],
      section.rows.contains(where: { $0.entityID == selected })
    {
      return selected
    }
    return section.candidateWashSourceItemID
  }

  /// Add new cards, re-point a card whose retained source was filtered away, and discard cards no
  /// longer in the model projection. Existing visible sources remain untouched when a later page
  /// changes the section's first row.
  func reconcile(_ sections: [AuthorSeriesSection]) {
    let sectionIDs = Set(sections.map(\.id))
    var next = sourceItemIDs.filter { sectionIDs.contains($0.key) }

    for section in sections {
      guard let candidate = section.candidateWashSourceItemID else { continue }
      if let selected = next[section.id],
        section.rows.contains(where: { $0.entityID == selected })
      {
        continue
      }
      next[section.id] = candidate
    }

    guard next != sourceItemIDs else { return }
    sourceItemIDs = next
  }
}

/// A bounded push onto one author's or series's item list, the destination an author/series search
/// hit lands on. The screen keeps the existing navigation and context-menu dependencies, but
/// presents the model's ordered sections as solid editorial cards.
struct AuthorSeriesView: View {
  /// The grid tile's request rung, reused for the detail-artwork preflight `LibraryShellView` fires
  /// on selection. Equals the 140-point `.homeCard` pair Home warms, not the tile's drawn width,
  /// so this destination fetches no second variant (washes are variant-independent).
  static let artworkDisplaySize = AuthorSeriesGridMetrics.coverDisplaySize

  @State private var deferredModel = DeferredModel<AuthorSeriesModel>()
  @State private var homeWashProvider: HomeWashProvider
  @State private var washSources: AuthorSeriesWashSourceStore
  @State private var bookZoomOccurrenceID = UUID()

  @Environment(\.displayScale) private var displayScale

  let makeModel: () -> AuthorSeriesModel
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let finishedStatus: FinishedStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelectItem: (ItemSummary) -> Void
  /// Opens the reader for an ebook row's long-press Read entry. The ebook counterpart of
  /// `onSelect`'s push, threaded from `LibraryShellView` the same way.
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void

  init(
    makeModel: @escaping () -> AuthorSeriesModel,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    finishedStatus: FinishedStatusStore,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    onSelectItem: @escaping (ItemSummary) -> Void,
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void,
    onSearch: @escaping (String) -> Void
  ) {
    self.makeModel = makeModel
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.finishedStatus = finishedStatus
    self.playback = playback
    self.actions = actions
    self.onSelectItem = onSelectItem
    self.onPresentReader = onPresentReader
    self.onSearch = onSearch
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: Self.artworkDisplaySize,
        displayScale: 1,
        artworkRole: .homeCard))
    _washSources = State(initialValue: AuthorSeriesWashSourceStore())
  }

  private var model: AuthorSeriesModel {
    deferredModel.resolve(makeModel)
  }

  var body: some View {
    content
      .environment(
        \.bookZoomTransitionOccurrencePrefix,
        "author-series-\(bookZoomOccurrenceID.uuidString)"
      )
      .onDisappear { homeWashProvider.retireAllScrollSources() }
      .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
      .navigationTitle(model.entity?.name ?? model.target.fallbackTitle)
      .navigationBarTitleDisplayMode(.inline)
      .onChange(of: model.sections) { _, sections in
        washSources.reconcile(sections)
      }
      .task {
        washSources.reconcile(model.sections)
      }
  }

  @ViewBuilder
  private var content: some View {
    switch model.state {
    case .loading:
      LoadingStateView(message: AuthorSeriesCopy.loadingMessage)
    case .empty:
      EmptyStateView(
        title: AuthorSeriesCopy.emptyTitle,
        message: AuthorSeriesCopy.emptyMessage(for: model.target),
        systemImage: AuthorSeriesCopy.emptySystemImage)
    case .filteredEmpty:
      EmptyStateView(
        title: AuthorSeriesCopy.filteredEmptyTitle,
        message: AuthorSeriesCopy.filteredEmptyMessage(for: model.target),
        systemImage: AuthorSeriesCopy.emptySystemImage)
    case .loaded:
      list
    }
  }

  private var list: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
        if let summary = seriesSummary {
          Text(summary)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WhirrSpacing.xSmall)
        }

        ForEach(displayGroups) { group in
          if group.leadingSectionID == standaloneHeaderSectionID {
            standaloneHeader
          }
          groupView(for: group)
        }

        if model.hasMore {
          ProgressView()
            .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
            .accessibilityLabel(AuthorSeriesCopy.loadingMoreLabel)
            .onAppear { Task { await model.loadMore() } }
        }
      }
      // The vertical inset is the ends of the rhythm the inter-card spacing sets: without it the
      // first and last cards butt against the scroll edges while every interior gap stays even.
      .padding(.horizontal, WhirrSpacing.medium)
      .padding(.vertical, WhirrSpacing.xSmall)
    }
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .primaryScrollEdgeEffect(role: .titled)
    .onScrollPhaseChange { _, phase in
      homeWashProvider.setScrollInteractionActive(
        phase, source: homeWashProvider.scrollSource(for: .authorSeriesOuter))
    }
    // The cache pass has already persisted one variant-independent wash per covered item. Read all
    // visible card sources together so a warm author opens coloured on its first frame; only true
    // record misses continue through the cards' lazy visible requests above.
    .task(id: Set(washPreloadSubjects)) {
      await homeWashProvider.preloadCachedWashes(washPreloadSubjects)
    }
  }

  private var displayGroups: [AuthorSeriesDisplayGroup] {
    AuthorSeriesDisplayGroup.groups(for: model.sections)
  }

  /// Loose books share one grid, each drawing its own card; everything the projection still groups
  /// keeps a card that owns a grid of its own.
  @ViewBuilder
  private func groupView(for group: AuthorSeriesDisplayGroup) -> some View {
    switch group {
    case .looseBooks(let sections):
      AuthorSeriesStandaloneBookGrid(
        sections: sections,
        target: model.target,
        washSourceItemID: washSources.sourceItemID(for:),
        wash: wash(for:),
        coverClient: coverClient,
        playbackProgress: model.playbackProgress(for:),
        finishedStatus: finishedStatus,
        playback: playback,
        actions: actions,
        onSelectItem: onSelectItem,
        onPresentReader: onPresentReader,
        onSearch: onSearch,
        onRequestWash: requestWash)
    case .card(let section):
      AuthorSeriesGridSection(
        section: section,
        target: model.target,
        hasMore: model.hasMore,
        sourceItemID: washSources.sourceItemID(for: section),
        wash: wash(for: section),
        coverClient: coverClient,
        playbackProgress: model.playbackProgress(for:),
        finishedStatus: finishedStatus,
        playback: playback,
        actions: actions,
        onSelectItem: onSelectItem,
        onPresentReader: onPresentReader,
        onSearch: onSearch,
        onRequestWash: requestWash)
    }
  }

  /// Drawn above the first loose book, outside any card: it labels the run that follows rather than
  /// claiming, as a card heading would, that the books beneath it are one collection.
  private var standaloneHeader: some View {
    Text(AuthorSeriesCopy.standaloneHeading)
      .font(WhirrTypeToken.title.font)
      .foregroundStyle(WhirrColorToken.textPrimary.color)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, WhirrSpacing.xSmall)
      .padding(.top, WhirrSpacing.small)
      .accessibilityAddTraits(.isHeader)
  }

  private var standaloneHeaderSectionID: String? {
    AuthorSeriesCopy.standaloneHeaderSectionID(for: model.sections, target: model.target)
  }

  /// A series destination's one quiet line above its card. The card there carries no heading (the
  /// navigation title already names the series), so this is the only place its author and edition
  /// count can appear. An author destination gets nil: its cards head themselves, and the author is
  /// the title of the screen.
  private var seriesSummary: String? {
    guard model.target.isSeriesDestination, let section = model.sections.first else { return nil }
    return AuthorSeriesCopy.seriesSummary(for: section, hasMore: model.hasMore)
  }

  /// Author and series cards are server items by construction, so their subjects carry no
  /// artwork source of their own.
  private var washPreloadSubjects: [EditorialWashSubject] {
    model.sections.compactMap { washSources.sourceItemID(for: $0) }.map(washSubject(for:))
  }

  /// The source item is one of the screen's own rows, which carries the revision every other
  /// surface keys that item's cover by.
  private func washSubject(for sourceItemID: String) -> EditorialWashSubject {
    let row = model.sections.lazy.flatMap(\.rows).first { $0.entityID == sourceItemID }
    return .audiobookshelf(sourceItemID, revision: row?.artworkRevision ?? .unversioned)
  }

  private func wash(for section: AuthorSeriesSection) -> CoverWash {
    // A section with no cover sits at its shelf's weight.
    guard let sourceItemID = washSources.sourceItemID(for: section) else {
      return CoverWash.drainedNeutral
    }
    return homeWashProvider.wash(for: washSubject(for: sourceItemID))
  }

  private func requestWash(_ sourceItemID: String) {
    homeWashProvider.request(
      [washSubject(for: sourceItemID)],
      intent: .visible,
      displaySize: Self.artworkDisplaySize,
      displayScale: displayScale,
      artworkRole: .homeCard)
  }
}
