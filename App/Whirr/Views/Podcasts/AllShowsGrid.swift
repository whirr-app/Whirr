import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import UniformTypeIdentifiers

/// One extra rotor action a source offers on every tile while editing, alongside the two moves.
struct AllShowsEditingAction {
  let label: String
  let perform: () -> Void
}

/// The all-shows grid both sources draw through: the server screen (`PodcastShowsView`) and the
/// followed-feed screen (`NativePodcastShowsView`). It owns the shared scroll host, header row,
/// tiles, edit-mode drag/drop/accessibility moves and wash plumbing, and knows neither model; each
/// screen keeps its toolbar, alerts, source-switch gate and editing-session lifecycle.
///
/// In edit mode tap and long-press belong to reordering: `PodcastShowsEditingSession` holds the
/// working order, a drag re-flows it locally, and the drop commits once. Nothing reaches the
/// database while a finger is down.
struct AllShowsGrid<Header: View, EditingOverlay: View>: View {
  let shows: [ItemSummary]
  @Binding var session: PodcastShowsEditingSession
  let placeholder: AllShowsPlaceholder?
  let coverClient: any ArtworkServing
  let playback: PlaybackModel
  let actions: ItemActionsModel
  /// While true, edit-mode tiles offer no drag, no move, and no `editingAction`. A write in flight
  /// must finish before the order changes under it.
  let reorderLocked: Bool
  /// Nil for a source with no attention state; tiles then reserve no attention row.
  let needsAttention: ((String) -> Bool)?
  let editingAction: (ItemSummary) -> AllShowsEditingAction?
  let onSelectShow: (ItemSummary) -> Void
  let onSearch: (String) -> Void
  let onRetry: () -> Void
  /// Persists a completed drag's order. The screen resyncs the session if the write is rejected,
  /// because only it can see the model's error.
  let commit: ([String]) async -> Void
  let move: (_ showID: String, _ destination: Int) async -> Void
  /// The host's source picker, rendered as this scroll view's first row rather than above it.
  /// See `PodcastShowsHostView` for why the navigation bar needs it as scroll content.
  let header: Header
  let editingOverlay: (ItemSummary) -> EditingOverlay

  /// Measured because the header moves with Dynamic Type and the placeholder must be centred in
  /// what is left below it. Otherwise the interactive error placeholder would cover the picker and
  /// strand the user on a source they cannot switch away from.
  @State private var headerHeight: CGFloat = 0
  @State private var availableWidth: CGFloat = 0
  @State private var homeWashProvider: HomeWashProvider
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  /// Computed, not stored: this type is generic, and a generic type cannot hold a static stored
  /// property.
  private static var cardSize: CGFloat { HomeView.cardCoverSize }

  init(
    shows: [ItemSummary],
    session: Binding<PodcastShowsEditingSession>,
    placeholder: AllShowsPlaceholder?,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    reorderLocked: Bool = false,
    needsAttention: ((String) -> Bool)? = nil,
    editingAction: @escaping (ItemSummary) -> AllShowsEditingAction? = { _ in nil },
    onSelectShow: @escaping (ItemSummary) -> Void,
    onSearch: @escaping (String) -> Void,
    onRetry: @escaping () -> Void = {},
    commit: @escaping ([String]) async -> Void,
    move: @escaping (_ showID: String, _ destination: Int) async -> Void,
    @ViewBuilder header: () -> Header,
    @ViewBuilder editingOverlay: @escaping (ItemSummary) -> EditingOverlay
  ) {
    self.shows = shows
    _session = session
    self.placeholder = placeholder
    self.coverClient = coverClient
    self.playback = playback
    self.actions = actions
    self.reorderLocked = reorderLocked
    self.needsAttention = needsAttention
    self.editingAction = editingAction
    self.onSelectShow = onSelectShow
    self.onSearch = onSearch
    self.onRetry = onRetry
    self.commit = commit
    self.move = move
    self.header = header()
    self.editingOverlay = editingOverlay
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: Self.cardSize, displayScale: 1, artworkRole: .homeCard))
  }

  /// The Podcasts root's page column: the base margin on every device, centring the page only in a
  /// window wider than the page maximum.
  private var pageColumnInset: CGFloat {
    PodcastsViewPresentation.pageColumnInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  private var reorderAnimation: Animation? {
    PodcastShowsViewPresentation.reorderAnimation(reduceMotion: reduceMotion)
  }

  var body: some View {
    let tiles = PodcastShowsViewPresentation.tiles(shows, in: session)
    // The host shows one source at a time, so both share this one scroll source id.
    let source = homeWashProvider.scrollSource(for: .allShowsOuter)
    let gridNeedsAttention =
      needsAttention.map { check in tiles.contains { check($0.serverItemId) } } ?? false

    ScrollView {
      VStack(spacing: 0) {
        // Measured outside its padding, unlike Home's filter row: this height insets a placeholder
        // that would otherwise cover the picker, so it must cover the whole occupied band.
        header
          // The chip strip carries `WhirrSpacing.medium` itself; only the page inset's excess
          // belongs out here, as on the Podcasts root's filter row.
          .padding(.horizontal, pageColumnInset - WhirrSpacing.medium)
          .padding(.top, HomePodcastsBrowseLayout.filterRowTopSpacing)
          .onGeometryChange(for: CGFloat.self) {
            $0.size.height
          } action: {
            headerHeight = $0
          }

        LazyVGrid(columns: showColumns, alignment: .leading, spacing: WhirrSpacing.medium) {
          ForEach(Array(tiles.enumerated()), id: \.element.id) { index, show in
            showTile(
              show, index: index, count: tiles.count, gridNeedsAttention: gridNeedsAttention)
          }
        }
        .animation(reorderAnimation, value: shows.map(\.serverItemId))
        .padding(.horizontal, pageColumnInset)
        .padding(.vertical, WhirrSpacing.medium)
      }
    }
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.width
    } action: { width in
      availableWidth = width
    }
    .primaryScrollEdgeEffect(role: .titled)
    .onScrollPhaseChange { _, phase in
      homeWashProvider.setScrollInteractionActive(phase, source: source)
    }
    .onDisappear { homeWashProvider.retireScrollSource(source) }
    // Keyed on the id set so a reorder does not repeat the records-only warm.
    .task(id: Set(shows.map(\.serverItemId))) {
      await homeWashProvider.preloadCachedWashes(shows.map(\.washSubject))
    }
    // An overlay, not grid content: the placeholder must never add height to the scroll host.
    .overlay {
      if let placeholder {
        placeholderView(placeholder)
          .allowsHitTesting(placeholder.allowsHitTesting)
          // Keeps the placeholder clear of the picker, which shares the scroll view's bounds. The
          // error placeholder is interactive, so without this inset it would swallow taps on the
          // chips and leave a failing source with no way back.
          .padding(.top, headerHeight)
      }
    }
  }

  @ViewBuilder
  private func placeholderView(_ placeholder: AllShowsPlaceholder) -> some View {
    switch placeholder {
    case .loading(let message):
      LoadingStateView(message: message)
    case .empty(let title, let message, let systemImage):
      EmptyStateView(title: title, message: message, systemImage: systemImage)
    case .error(let title, let message, let systemImage, let action):
      EmptyStateView(
        title: title,
        message: message,
        systemImage: systemImage,
        actionLabel: action.label
      ) {
        switch action {
        case .retry: onRetry()
        }
      }
    }
  }

  private var showColumns: [GridItem] {
    [
      GridItem(
        .adaptive(
          minimum: PodcastsViewPresentation.showGridTileWidth(
            isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)),
        spacing: WhirrSpacing.small,
        alignment: .top)
    ]
  }

  @ViewBuilder
  private func showTile(
    _ show: ItemSummary, index: Int, count: Int, gridNeedsAttention: Bool
  ) -> some View {
    let tile = PodcastShowTileView(
      show: show, coverClient: coverClient, cardSize: Self.cardSize,
      wash: homeWashProvider.wash(for: show.washSubject),
      attentionRow: needsAttention.map {
        PodcastsViewPresentation.showTileAttentionRow(
          needsAttention: $0(show.serverItemId), gridNeedsAttention: gridNeedsAttention)
      } ?? .omitted,
      onSelect: {
        guard PodcastShowsViewPresentation.tileIsSelectable(isEditing: session.isEditing) else {
          return
        }
        onSelectShow(show)
      }
    )
    .onAppear {
      homeWashProvider.request(
        [show.washSubject], intent: .visible, displayScale: displayScale, artworkRole: .homeCard)
    }

    if PodcastShowsViewPresentation.contextMenuIsEnabled(isEditing: session.isEditing) {
      tile.itemContextMenu(
        ItemMenuSubject(
          show: show, coverClient: coverClient, playback: playback, actions: actions),
        placement: .podcastAllShowsPageTile,
        onOpen: { onSelectShow(show) }, onSearch: onSearch)
    } else {
      editingShowTile(tile, show: show, index: index, count: count)
    }
  }

  @ViewBuilder
  private func editingShowTile(
    _ tile: some View, show: ItemSummary, index: Int, count: Int
  ) -> some View {
    let accessibleTile = accessibleEditingTile(tile, show: show, index: index, count: count)

    ZStack(alignment: .topLeading) {
      if reorderLocked {
        accessibleTile
      } else {
        withEditingAction(accessibleTile, show: show)
          .onDrag {
            session.beginDrag(show.serverItemId)
            return NSItemProvider(object: show.serverItemId as NSString)
          }
          .onDrop(
            of: [.text],
            delegate: AllShowsDropDelegate(
              targetID: show.serverItemId, session: $session, animation: reorderAnimation,
              onCommit: { order in Task { await commit(order) } }))
      }

      editingOverlay(show)
    }
  }

  @ViewBuilder
  private func withEditingAction(_ tile: some View, show: ItemSummary) -> some View {
    if let action = editingAction(show) {
      tile.accessibilityAction(named: Text(action.label)) { action.perform() }
    } else {
      tile
    }
  }

  /// Attaches the accessibility moves and positional value to a tile in edit mode. Move
  /// Earlier/Move Later go through `move`, the same persistence path a completed drag commits
  /// through, and each is omitted at its boundary rather than exposed disabled, so VoiceOver never
  /// announces a no-op action.
  @ViewBuilder
  private func accessibleEditingTile(
    _ tile: some View, show: ItemSummary, index: Int, count: Int
  ) -> some View {
    let moves = PodcastShowsViewPresentation.accessibilityMoveActions(
      isEditing: session.isEditing && reorderLocked == false, index: index, count: count)
    if moves.isEmpty {
      tile
    } else {
      rotorMoves(on: tile, show: show, index: index, count: count, moves: moves)
        // WCAG 2.5.7: the rotor actions are VoiceOver-only, so this is the non-drag pointer route.
        // Edit mode turns the item context menu off (`contextMenuIsEnabled`) to free the long
        // press. Boundary moves stay listed and greyed: a menu that changes length is worse.
        .contextMenu {
          Button(PodcastShowAccessibilityMove.earlier.label, systemImage: "arrow.up") {
            performMove(.earlier, showID: show.serverItemId, index: index)
          }
          .disabled(moves.contains(.earlier) == false)
          Button(PodcastShowAccessibilityMove.later.label, systemImage: "arrow.down") {
            performMove(.later, showID: show.serverItemId, index: index)
          }
          .disabled(moves.contains(.later) == false)
        }
    }
  }

  /// The rotor actions and positional value.
  @ViewBuilder
  private func rotorMoves(
    on tile: some View, show: ItemSummary, index: Int, count: Int,
    moves: [PodcastShowAccessibilityMove]
  ) -> some View {
    switch (moves.contains(.earlier), moves.contains(.later)) {
    case (true, true):
      tile
        .accessibilityValue(
          PodcastShowsViewPresentation.accessibilityPositionValue(index: index, count: count)
        )
        .accessibilityAction(named: Text(PodcastShowAccessibilityMove.earlier.label)) {
          performMove(.earlier, showID: show.serverItemId, index: index)
        }
        .accessibilityAction(named: Text(PodcastShowAccessibilityMove.later.label)) {
          performMove(.later, showID: show.serverItemId, index: index)
        }
    case (true, false):
      tile
        .accessibilityValue(
          PodcastShowsViewPresentation.accessibilityPositionValue(index: index, count: count)
        )
        .accessibilityAction(named: Text(PodcastShowAccessibilityMove.earlier.label)) {
          performMove(.earlier, showID: show.serverItemId, index: index)
        }
    case (false, true):
      tile
        .accessibilityValue(
          PodcastShowsViewPresentation.accessibilityPositionValue(index: index, count: count)
        )
        .accessibilityAction(named: Text(PodcastShowAccessibilityMove.later.label)) {
          performMove(.later, showID: show.serverItemId, index: index)
        }
    case (false, false):
      tile
    }
  }

  private func performMove(
    _ direction: PodcastShowAccessibilityMove, showID: String, index: Int
  ) {
    Task {
      await move(showID, PodcastShowsViewPresentation.destination(for: direction, at: index))
    }
  }
}

/// One delegate per tile: hovering re-flows the working order with animation, and the drop hands
/// the completed sequence over once. A drag released outside any tile never commits; the next
/// model observation (or Done) resyncs the working order.
private struct AllShowsDropDelegate: DropDelegate {
  let targetID: String
  @Binding var session: PodcastShowsEditingSession
  let animation: Animation?
  let onCommit: ([String]) -> Void

  func dropEntered(info: DropInfo) {
    withAnimation(animation) { session.dragEntered(targetID) }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

  func performDrop(info: DropInfo) -> Bool {
    if let order = session.completeDrag() { onCommit(order) }
    return true
  }
}
