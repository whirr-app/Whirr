import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The all-shows page: the complete, ordered server-show grid the Podcasts root's bounded
/// six-show preview pushes to. Shares one `PodcastShowsModel` with the root (`RootComposition`).
/// The grid and reordering are `AllShowsGrid`'s; this screen owns the toolbar, sort menu, alerts,
/// refresh and editing-session lifecycle.
struct PodcastShowsView<Header: View>: View {
  @Bindable var model: PodcastShowsModel
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelectShow: (ItemSummary) -> Void
  let onSearch: (String) -> Void
  /// The combined all-shows host asks the active child to finish its normal Done path before a
  /// source switch. Nil keeps this view source-compatible for focused previews/tests.
  let sourceSwitchGate: PodcastShowsSourceSwitchGate?
  /// The host's source picker, rendered as this scroll view's first row rather than above it.
  /// See `PodcastShowsHostView` for why the navigation bar needs it to be scroll content.
  let header: Header

  @State private var session = PodcastShowsEditingSession()
  @State private var resetConfirmation = PodcastShowsResetConfirmation()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    model: PodcastShowsModel,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    onSelectShow: @escaping (ItemSummary) -> Void,
    onSearch: @escaping (String) -> Void,
    sourceSwitchGate: PodcastShowsSourceSwitchGate? = nil,
    @ViewBuilder header: () -> Header
  ) {
    _model = Bindable(model)
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.playback = playback
    self.actions = actions
    self.onSelectShow = onSelectShow
    self.onSearch = onSearch
    self.sourceSwitchGate = sourceSwitchGate
    self.header = header()
  }

  private var shows: [ItemSummary] { PodcastShowsViewPresentation.shows(in: model.state) }
  private var modelOrder: [String] { shows.map(\.serverItemId) }

  var body: some View {
    content
      .itemActionErrorAlert(actions)
      .refreshable { await model.refresh() }
      .toolbar {
        if PodcastShowsViewPresentation.editButtonIsAvailable(
          isEditing: session.isEditing, isEditingAllowed: model.isEditingAllowed)
        {
          ToolbarItem(placement: .topBarTrailing) {
            Button(PodcastShowsViewPresentation.editButtonTitle(isEditing: session.isEditing)) {
              withAnimation(
                PodcastShowsViewPresentation.editModeAnimation(reduceMotion: reduceMotion)
              ) {
                if session.isEditing {
                  session.endEditing()
                } else {
                  session.beginEditing(order: modelOrder)
                }
              }
            }
          }
        }
        if PodcastShowsViewPresentation.sortMenuIsAvailable(isEditing: session.isEditing) {
          ToolbarItem(placement: .topBarTrailing) { sortMenu }
        }
      }
      .onAppear {
        session.observe(order: modelOrder)
        sourceSwitchGate?.register(source: .server, prepare: prepareForSourceSwitch)
      }
      .onDisappear { sourceSwitchGate?.unregister(source: .server) }
      .onChange(of: modelOrder) { _, order in session.observe(order: order) }
      .onChange(of: model.isEditingAllowed) { _, allowed in
        session.syncGate(isEditingAllowed: allowed, order: modelOrder)
      }
      // One alert at screen scope, not one per tile.
      .alert(
        PodcastShowsViewPresentation.navigationTitle,
        isPresented: Binding(
          get: { model.actionErrorMessage != nil },
          set: { if $0 == false { model.dismissActionError() } })
      ) {
        Button("OK", role: .cancel) { model.dismissActionError() }
      } message: {
        Text(model.actionErrorMessage ?? "")
      }
      // Only the Reset row's `resetConfirmation.request()` presents this, and only its Reset
      // Order button calls the model, so a reset cannot happen accidentally. The menu has
      // collapsed by then, so the confirmation needs a stable, centred alert host.
      .alert(
        PodcastShowsViewPresentation.resetConfirmationTitle,
        isPresented: Binding(
          get: { resetConfirmation.isPresented },
          set: { if $0 == false { resetConfirmation.cancel() } })
      ) {
        Button(
          PodcastShowsViewPresentation.resetConfirmationConfirmLabel, role: .destructive
        ) {
          resetConfirmation.confirm()
          Task { await model.resetToAlphabetical() }
        }
        Button(PodcastShowsViewPresentation.resetConfirmationCancelLabel, role: .cancel) {
          resetConfirmation.cancel()
        }
      } message: {
        Text(PodcastShowsViewPresentation.resetConfirmationMessage)
      }
  }

  /// Called synchronously by `PodcastShowsHostView` before it changes the segmented picker. A
  /// visible reset alert belongs to this child, so changing source while it is up would strand the
  /// alert and lose the user's decision; leave the picker where it is until it resolves.
  private func prepareForSourceSwitch() -> Bool {
    guard resetConfirmation.isPresented == false else { return false }
    session.endEditing()
    return true
  }

  /// Read-only mode only: reports the current sort mode and, only in Custom, offers Reset to
  /// Alphabetical. The row only requests confirmation; it never calls the model.
  private var sortMenu: some View {
    Menu {
      Text(PodcastShowsViewPresentation.sortModeLabel(model.sortMode))
      if PodcastShowsViewPresentation.resetIsOffered(mode: model.sortMode) {
        Button(role: .destructive) {
          resetConfirmation.request()
        } label: {
          Label(
            PodcastShowsViewPresentation.resetMenuActionLabel,
            systemImage: "arrow.counterclockwise")
        }
      }
    } label: {
      Label("Sort", systemImage: "arrow.up.arrow.down")
    }
  }

  private var content: some View {
    // The grid overlays the placeholder on the scroll host: it never becomes scroll content.
    AllShowsGrid(
      shows: shows,
      session: $session,
      placeholder: PodcastShowsViewPresentation.placeholder(for: model.state),
      coverClient: coverClient,
      paletteService: paletteService,
      playback: playback,
      actions: actions,
      onSelectShow: onSelectShow,
      onSearch: onSearch,
      onRetry: { Task { await model.refresh() } },
      commit: { order in
        await model.apply(order: order)
        // A rejected write leaves the observed order unchanged, so nothing would resync the
        // working order on its own, so snap it back to the persisted order here.
        if model.actionErrorMessage != nil { session.observe(order: modelOrder) }
      },
      // Reuses `PodcastShowsModel.move`, the funnel drag reordering also commits through.
      move: { itemID, destination in await model.move(itemID: itemID, to: destination) },
      header: { header },
      editingOverlay: { _ in EmptyView() })
  }
}
