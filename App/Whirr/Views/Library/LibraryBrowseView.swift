import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

#if PERF_INVESTIGATION
  import QuartzCore
#endif

/// The Library root owns browse selection. Each entity list is created on first visit and kept
/// while the tab lives, so the initial Titles screen does no extra network work and switching
/// back doesn't reload.
///
/// Compact keeps the live `List` that owns the navigation bar's scroll surface; regular uses the
/// measured grid, with the same retained models. Replacing the scroll view under a navigation bar
/// makes UIKit re-run the large title's appearance ("Library" flashes on every mode tap), so both
/// presentations live under one retained screen.
struct LibraryBrowseRootView: View {
  @Binding var mode: LibraryBrowsePresentation.Mode
  let selectionEntry: LibrarySelectionEntry
  @Bindable var browseModel: LibraryBrowseModel
  let authorSeriesReading: any AuthorSeriesReading
  let libraryCollections: LibraryCollectionsAccess
  let coverClient: any ArtworkServing
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let onSelectTitle: (ItemSummary) -> Void
  let onSelectEntity: (LibraryEntityGroup) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void
  let onSelectCollection: (LibraryCollectionKey) -> Void
  /// Bumped by the shell on every Library tab reselect. See `LibraryReselectRequests`.
  let scrollToTopRequest: Int
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var authorsModel: AuthorSeriesBrowseModel?
  @State private var seriesModel: AuthorSeriesBrowseModel?
  @State private var collectionsModel: LibraryCollectionsBrowseModel?
  /// Transient root state that survives a mode switch and a push/pop for as long as this root
  /// lives. Never persisted.
  @State private var queryText = ""
  @State var selection = BatchSelectionController<String, LibraryBrowsePresentation.SelectionAction>()
  /// Held here, not in the Titles rows, so a mode switch does not rebuild it and its cancellation
  /// follows the list it prefetches for.
  @State private var artworkPrefetcher = DirectionalArtworkPrefetcher()
  /// The regular grid uses the shared 140pt home-card rung while compact rows keep the smaller
  /// library-thumbnail request. Both are screen-scoped so a mode switch never creates a prefetcher
  /// per tile.
  @State private var regularArtworkPrefetcher = DirectionalArtworkPrefetcher(artworkRole: .homeCard)
  @State private var scrollPosition = ScrollPosition()
  /// The compact list's reselect scroll. A `ScrollPosition` edge stops at the top of the content,
  /// below the collapsed `.searchable` drawer, and lands short across unmeasured rows.
  @State private var reselectScroller = LibraryReselectScroller()
  /// The regular branch's A to Z jump, executed by its collection view. The compact `List` never
  /// jumps, so `scrollPosition` serves it alone.
  @State private var jumpRequest: LibraryBrowseJumpRequest?
  /// Held outside observed state (see `LibraryScrollActivity`). A phase change writes here and
  /// nowhere a `body` can see, so a fling costs no view invalidation of its own.
  @State private var scrollActivity: LibraryScrollActivity
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(
    mode: Binding<LibraryBrowsePresentation.Mode>,
    selectionEntry: LibrarySelectionEntry,
    browseModel: LibraryBrowseModel,
    authorSeriesReading: any AuthorSeriesReading,
    libraryCollections: LibraryCollectionsAccess,
    coverClient: any ArtworkServing,
    downloadStatus: DownloadStatusStore,
    finishedStatus: FinishedStatusStore,
    actions: ItemActionsModel,
    playback: PlaybackModel,
    onSelectTitle: @escaping (ItemSummary) -> Void,
    onSelectEntity: @escaping (LibraryEntityGroup) -> Void,
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void,
    onSearch: @escaping (String) -> Void,
    onSelectCollection: @escaping (LibraryCollectionKey) -> Void,
    scrollToTopRequest: Int
  ) {
    _mode = mode
    self.selectionEntry = selectionEntry
    _browseModel = Bindable(browseModel)
    self.authorSeriesReading = authorSeriesReading
    self.libraryCollections = libraryCollections
    self.coverClient = coverClient
    self.downloadStatus = downloadStatus
    self.finishedStatus = finishedStatus
    self.actions = actions
    self.playback = playback
    self.onSelectTitle = onSelectTitle
    self.onSelectEntity = onSelectEntity
    self.onPresentReader = onPresentReader
    self.onSearch = onSearch
    self.onSelectCollection = onSelectCollection
    self.scrollToTopRequest = scrollToTopRequest
    _scrollActivity = State(initialValue: LibraryScrollActivity())
  }

  var body: some View {
    @Bindable var entry = selectionEntry
    // Derived once per evaluation, not once per observer: recomputing `selectableTitles` per
    // `onChange` operand would run the O(n) selection filter over the whole library twice on the
    // main actor at the moment scroll deferral lifts.
    let selectable = selectableTitles
    let selectableIDs = Set(selectable.map(\.serverItemId))

    // Composed from named segments, innermost first, so the modifier order is unchanged.
    browseLifecycle(
      browseOverlay(
        selectionConfirmAlert(
          selectionObservers(
            listChrome(scrollContent)
              .environment(\.editMode, $entry.editMode),
            selectableIDs: selectableIDs,
            hasSelectableRows: selectable.isEmpty == false))))
  }

  /// The title, the Select control and the access they gate, applied to whichever scroll surface
  /// is on screen.
  private func listChrome(_ content: some View) -> some View {
    content
      .disabled(selection.isPerforming)
      // The title lives in this root so selection can rename it; large-title flashes come from
      // replacing the scroll view beneath the bar, not from where the title is declared. The
      // display mode set here overrides the shell's, so it must state the shell's choice again.
      .selectionChrome(
        isSelecting: selectionEntry.editMode.isEditing,
        selectionTitle: selectionTitle,
        title: "Library",
        titleDisplayMode: LibraryShellPresentation.usesInlineLargeTitle(in: .library)
          ? .inlineLarge : .automatic
      )
      .toolbar { selectionToolbar }
      .toolbar(selectionEntry.editMode.isEditing ? .hidden : .automatic, for: .tabBar)
      .hidesPlayerAccessory(whileSelecting: selectionEntry.editMode.isEditing)
  }

  /// The selection facts derived once in `body`: the row IDs and whether any row can be selected.
  /// Passing them in keeps the O(n) filter from running again per `onChange` operand.
  private func selectionObservers(
    _ content: some View,
    selectableIDs: Set<String>,
    hasSelectableRows: Bool
  ) -> some View {
    content
      .onChange(of: selectionEntry.editMode) { _, mode in
        if !mode.isEditing { selection.selected.removeAll() }
      }
      .onChange(of: selectableIDs) { _, ids in selection.selected.formIntersection(ids) }
      .onChange(of: mode) { _, _ in selectionEntry.editMode = .inactive }
      .onChange(of: hasSelectableRows, initial: true) { _, hasRows in
        selectionEntry.hasSelectableRows = hasRows
      }
  }

  private func selectionConfirmAlert(_ content: some View) -> some View {
    content
      .alert(
        selection.pending.map { $0.action.confirmationButtonTitle(affectedCount: $0.ids.count) + "?" }
          ?? "Selected Titles",
        isPresented: Binding(get: { selection.pending != nil }, set: { _ in })
      ) {
        Button("Cancel", role: .cancel) { selection.cancelPending() }
        Button(
          selection.pending.map { $0.action.confirmationButtonTitle(affectedCount: $0.ids.count) } ?? "Confirm",
          role: selection.pending?.action == .removeDownloads ? .destructive : nil
        ) {
          selection.confirmPending { performSelectionAction($0, ids: $1) }
        }
      } message: {
        Text(
          selection.pending.map { $0.action.confirmationMessage(affectedCount: $0.ids.count) } ?? "")
      }
  }

  /// The quick filter, the non-row states, and the Library tab's reselect scroll.
  private func browseOverlay(_ content: some View) -> some View {
    content
      .searchable(
        text: $queryText,
        placement: .navigationBarDrawer(displayMode: .automatic),
        prompt: Text(LibraryBrowsePresentation.quickFilterPrompt(for: mode))
      )
      .overlay {
        modeOverlay
      }
      .onChange(of: scrollToTopRequest) { _, _ in
        reselectScroller.scrollToTop(animated: reduceMotion == false)
      }
  }

  /// The error alert and the observers that keep the models, prefetchers and deferral in step.
  private func browseLifecycle(_ content: some View) -> some View {
    content
      // One alert for the whole list, not one attached to every row.
      .itemActionErrorAlert(actions, isSuppressed: selection.isPerforming)
      // Released together and unconditionally: a tab left mid-deceleration never delivers `.idle`,
      // so a standing deferral would freeze these rows until the reader scrolled again.
      .onDisappear {
        artworkPrefetcher.cancel()
        regularArtworkPrefetcher.cancel()
        scrollActivity.retireAllScrollSources()
        ArtworkScrollActivity.shared.setScrolling(false, source: "libraryBrowse")
        browseModel.setPresentationDeferred(false)
      }
      // The funnel writes to `browseModel`, the sole owner of the Library filter. Pushing the new
      // value into whichever entity models exist keeps all three modes narrowing on the same
      // value without a second stored copy.
      .onChange(of: browseModel.filters) { _, filters in
        authorsModel?.updateFilters(filters)
        seriesModel?.updateFilters(filters)
        collectionsModel?.updateFilters(filters)
      }
      // Authors and Series are pushed Titles' rendered projection, not separately observed, so the
      // modes can't disagree about the filter and the presentation deferral holds all three.
      // Only the engaged mode is fed (`selectMode` pushes when one becomes visible); regrouping an
      // offscreen model on every commit is wasted work.
      .onChange(of: browseModel.state) { _, state in
        entityModel(for: mode)?.updateItems(LibraryBrowsePresentation.items(in: state))
      }
      // Any query change resets the prefetcher: `DirectionalArtworkPrefetcher.observe` is driven
      // only by a row's `.onAppear`, and a row that survives a narrowing is never re-created, so
      // it would keep the pre-query `orderedIDs` and a stale `previousVisibleIndex`.
      .onChange(of: queryText) { _, _ in
        artworkPrefetcher.cancel()
        regularArtworkPrefetcher.cancel()
      }
  }

  @ViewBuilder
  private var scrollContent: some View {
    // A system List supplies native multi-selection on iPad too; browsing keeps its cover grid.
    switch selectionEntry.editMode.isEditing
      ? .nativeList
      : LibraryBrowseLayoutPresentation.indexOwner(for: horizontalSizeClass, mode: mode)
    {
    case .nativeList:
      compactContent
        .libraryBrowseScrollBehavior(
          scrollPosition: $scrollPosition,
          onRefresh: { await refreshCurrentMode() },
          onScrollPhaseChange: handleScrollPhase)
    case .jumpMenu:
      // No `libraryBrowseScrollBehavior` here: the regular branch is a UIKit collection view that
      // owns its refresh control and reports its own phases, and a SwiftUI scroll modifier above it
      // would reach the mode picker's chip rail instead.
      regularContent
    }
  }

  private var compactContent: some View {
    List(selection: selectionEntry.editMode.isEditing ? $selection.selected : nil) {
      modePicker
        .background { LibraryReselectScrollCapture(scroller: reselectScroller) }
        .disabled(selectionEntry.editMode.isEditing)
        .selectionDisabled()
        .plainListRow(top: WhirrSpacing.medium, bottom: WhirrSpacing.small)

      // Applied per row, since each mode contributes a group of rows rather than one view.
      // Podcasts fades `filterContent` the same way.
      modeRows
        .transition(.opacity)
    }
    .libraryIndexedListStyle(
      sectionIndexVisibility: LibraryBrowsePresentation.sectionIndexVisibility(
        isQueryEffective: LibraryQuickFilter.isEffective(queryText)),
      isSelecting: selectionEntry.editMode.isEditing
    )
    .selectionMarkTint(isSelecting: selectionEntry.editMode.isEditing)
  }

  private var regularContent: some View {
    LibraryBrowseRegularContent(
      mode: mode,
      browseModel: browseModel,
      authorsModel: authorsModel,
      seriesModel: seriesModel,
      query: queryText,
      coverClient: coverClient,
      downloadStatus: downloadStatus,
      finishedStatus: finishedStatus,
      actions: actions,
      playback: playback,
      artworkPrefetcher: regularArtworkPrefetcher,
      onSelectTitle: onSelectTitle,
      onSelectEntity: onSelectEntity,
      onPresentReader: onPresentReader,
      onSearch: onSearch,
      onJumpToTarget: { targetID in
        jumpRequest = LibraryBrowseJumpRequest(
          targetID: targetID, serial: (jumpRequest?.serial ?? 0) + 1)
        // The SwiftUI grid arm's jump, until that arm is retired.
        withAnimation(reduceMotion ? nil : .default) {
          scrollPosition.scrollTo(id: targetID, anchor: .top)
        }
      },
      scrollToTopRequest: scrollToTopRequest,
      jumpRequest: jumpRequest,
      scrollPosition: $scrollPosition,
      onRefresh: { await refreshCurrentMode() },
      onScrollPhaseChange: handleScrollPhase,
      modePicker: { modePicker }
    )
  }

  @ViewBuilder
  private var modeRows: some View {
    switch mode {
    case .titles:
      LibraryBrowseTitlesView(
        model: browseModel,
        coverClient: coverClient,
        downloadStatus: downloadStatus,
        finishedStatus: finishedStatus,
        actions: actions,
        playback: playback,
        query: queryText,
        artworkPrefetcher: artworkPrefetcher,
        onSelect: onSelectTitle,
        onPresentReader: onPresentReader,
        onSearch: onSearch
      )
    case .authors:
      if let authorsModel {
        entityRows(authorsModel)
      }
    case .series:
      if let seriesModel {
        entityRows(seriesModel)
      }
    case .collections:
      if let collectionsModel {
        LibraryBrowseCollectionsView(
          model: collectionsModel, query: queryText, onSelect: onSelectCollection,
          onClearFilters: { browseModel.clearFilters() })
      }
    }
  }

  private func handleScrollPhase(_ phase: ScrollPhase) {
    // Expensive Library presentation waits for the list or grid to stop moving. Persistence, the
    // sync and the quick filter over the rendered rows are untouched; only the moment a
    // replacement projection reaches SwiftUI moves.
    guard let isScrolling = scrollActivity.setScrollInteractionActive(phase, source: .root)
    else { return }
    ArtworkScrollActivity.shared.setScrolling(isScrolling, source: "libraryBrowse")
    browseModel.setPresentationDeferred(isScrolling)
  }

  private func entityRows(_ model: AuthorSeriesBrowseModel) -> some View {
    LibraryBrowseEntitiesView(
      model: model,
      coverClient: coverClient,
      query: queryText,
      onSelect: onSelectEntity,
      onClearFilters: { browseModel.clearFilters() }
    )
  }

  /// The non-row states (loading, empty, error) sit over the list rather than in it, for every
  /// mode. `filteredEmpty` is not here: it carries the way out of itself, and an overlay that
  /// drops hit testing would take that button with it.
  @ViewBuilder
  private var modeOverlay: some View {
    switch mode {
    case .titles:
      if let placeholder = LibraryBrowsePresentation.placeholder(
        for: browseModel.state, filters: browseModel.filters)
      {
        titlePlaceholder(placeholder)
          .allowsHitTesting(placeholder.allowsHitTesting)
      }
    case .authors:
      if let authorsModel {
        entityPlaceholder(authorsModel)
      }
    case .series:
      if let seriesModel {
        entityPlaceholder(seriesModel)
      }
    case .collections:
      if let collectionsModel,
        let placeholder = LibraryCollectionsPresentation.placeholder(for: collectionsModel.state)
      {
        titlePlaceholder(placeholder)
          .allowsHitTesting(placeholder.allowsHitTesting)
      }
    }
  }

  @ViewBuilder
  private func titlePlaceholder(
    _ placeholder: LibraryBrowsePresentation.Placeholder
  ) -> some View {
    switch placeholder {
    case .loading(let message):
      LoadingStateView(message: message)
    case .empty(let title, let message, let systemImage):
      EmptyStateView(title: title, message: message, systemImage: systemImage)
    case .error(let title, let message, let systemImage, let action):
      ErrorStateView(
        title: title,
        message: message,
        systemImage: systemImage,
        retryTitle: action.label
      ) {
        switch action {
        case .retry:
          Task { await browseModel.refresh() }
        }
      }
    }
  }

  @ViewBuilder
  private func entityPlaceholder(_ model: AuthorSeriesBrowseModel) -> some View {
    switch model.state {
    case .loading:
      LoadingStateView(message: "Loading \(AuthorSeriesBrowseCopy.entityNoun(for: model.kind))…")
        .allowsHitTesting(false)
    case .empty:
      EmptyStateView(
        title: model.kind == .author ? "No Authors Yet" : "No Series Yet",
        message: model.kind == .author
          ? "Authors from your default library will appear here."
          : "Series from your default library will appear here.",
        systemImage: model.kind == .author ? "person.2" : "books.vertical"
      )
      .allowsHitTesting(false)
    case .error:
      ErrorStateView(
        title: "Couldn't Load \(model.kind == .author ? "Authors" : "Series")",
        message: "Pull to refresh or try again.",
        systemImage: "exclamationmark.triangle",
        retryTitle: "Retry"
      ) {
        Task { await model.refresh() }
      }
    case .loaded, .filteredEmpty:
      EmptyView()
    }
  }

  private var modePicker: some View {
    MediaFilterPicker(
      title: "Browse library",
      labels: LibraryBrowsePresentation.Mode.allCases.map(\.label),
      selectedIndex: LibraryBrowsePresentation.Mode.allCases.firstIndex(of: mode) ?? 0,
      style: .chips,
      onSelect: { index in
        guard LibraryBrowsePresentation.Mode.allCases.indices.contains(index) else { return }
        selectMode(LibraryBrowsePresentation.Mode.allCases[index])
      }
    )
  }

  var selectableTitles: [ItemSummary] {
    #if PERF_INVESTIGATION
      let started = CACurrentMediaTime()
      let result = LibraryBrowsePresentation.selectionItems(
        from: browseModel.quickFilteredItems(query: queryText))
      MicrostutterProbe.shared.note(
        "Library.selectableTitles", count: result.count, elapsed: CACurrentMediaTime() - started)
      return result
    #else
      LibraryBrowsePresentation.selectionItems(
        from: browseModel.quickFilteredItems(query: queryText))
    #endif
  }

  var selectableTitleIDs: Set<String> {
    #if PERF_INVESTIGATION
      let started = CACurrentMediaTime()
      let result = Set(selectableTitles.map(\.serverItemId))
      MicrostutterProbe.shared.note(
        "Library.selectableTitleIDs", count: result.count, elapsed: CACurrentMediaTime() - started)
      return result
    #else
      Set(selectableTitles.map(\.serverItemId))
    #endif
  }

  /// The entity model a mode draws, or none for Titles, which renders `browseModel.state`
  /// directly.
  private func entityModel(for mode: LibraryBrowsePresentation.Mode) -> AuthorSeriesBrowseModel? {
    switch mode {
    case .authors: authorsModel
    case .series: seriesModel
    case .titles, .collections: nil
    }
  }

  private func selectMode(_ nextMode: LibraryBrowsePresentation.Mode) {
    guard nextMode != mode else { return }
    switch nextMode {
    case .authors:
      if authorsModel == nil {
        authorsModel = AuthorSeriesBrowseModel(
          kind: .author, reading: authorSeriesReading, filters: browseModel.filters)
      }
      authorsModel?.updateItems(LibraryBrowsePresentation.items(in: browseModel.state))
    case .series:
      if seriesModel == nil {
        seriesModel = AuthorSeriesBrowseModel(
          kind: .series, reading: authorSeriesReading, filters: browseModel.filters)
      }
      seriesModel?.updateItems(LibraryBrowsePresentation.items(in: browseModel.state))
    case .collections:
      // Read from the local snapshot, so it needs no projection; created on first visit so a
      // cold cache is fetched only when the reader asks for the mode.
      if collectionsModel == nil {
        collectionsModel = LibraryCollectionsBrowseModel(
          reading: libraryCollections.reading, fill: libraryCollections.fill,
          pins: libraryCollections.pins,
          filters: browseModel.filters)
      }
    case .titles:
      break
    }
    // Reuses the Podcasts root's transaction. The shared picker owns the moving selected chip;
    // this gives the content replacement beneath it the same opacity settle.
    withAnimation(PodcastsViewPresentation.filterChangeMotion(reduceMotion: reduceMotion)) {
      mode = nextMode
    }
  }

  /// One meaning for the gesture in every mode: sync the library, then reload whatever is on
  /// screen. Titles is served straight from the synced store, so the sync is the whole refresh;
  /// authors and series are paged reads layered on top of it and reload after it, not instead.
  private func refreshCurrentMode() async {
    await browseModel.refresh()
    switch mode {
    case .titles:
      break
    case .authors:
      if let authorsModel { await authorsModel.refresh() }
    case .series:
      if let seriesModel { await seriesModel.refresh() }
    case .collections:
      if let collectionsModel { await collectionsModel.refresh() }
    }
  }
}

/// Scroll behaviour shared by both Library presentations. Applied to the concrete `List` or
/// `ScrollView` branch so refresh and phase callbacks reach the right scroll source, while
/// `LibraryBrowseRootView` owns the position and the one deferral decision.
private struct LibraryBrowseScrollBehavior: ViewModifier {
  @Binding var scrollPosition: ScrollPosition
  let onRefresh: () async -> Void
  let onScrollPhaseChange: (ScrollPhase) -> Void

  init(
    scrollPosition: Binding<ScrollPosition>,
    onRefresh: @escaping () async -> Void,
    onScrollPhaseChange: @escaping (ScrollPhase) -> Void
  ) {
    self._scrollPosition = scrollPosition
    self.onRefresh = onRefresh
    self.onScrollPhaseChange = onScrollPhaseChange
  }

  func body(content: Content) -> some View {
    content
      .scrollPosition($scrollPosition)
      .refreshable { await onRefresh() }
      .onScrollPhaseChange { _, phase in
        onScrollPhaseChange(phase)
      }
  }
}

extension View {
  fileprivate func libraryBrowseScrollBehavior(
    scrollPosition: Binding<ScrollPosition>,
    onRefresh: @escaping () async -> Void,
    onScrollPhaseChange: @escaping (ScrollPhase) -> Void
  ) -> some View {
    modifier(
      LibraryBrowseScrollBehavior(
        scrollPosition: scrollPosition,
        onRefresh: onRefresh,
        onScrollPhaseChange: onScrollPhaseChange)
    )
  }
}
