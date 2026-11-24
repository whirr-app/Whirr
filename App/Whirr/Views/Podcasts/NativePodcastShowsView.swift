import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// Current editorial all-shows presentation backed by the device-owned native collection. The grid
/// itself is `AllShowsGrid`; this screen owns the followed source's toolbar, sort picker, alerts,
/// unfollow control, and editing-session lifecycle.
struct NativePodcastShowsView<Header: View>: View {
  @Bindable var model: NativePodcastShowsModel
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
  @State private var unfollowConfirmation = NativePodcastUnfollowConfirmation()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Computed, not stored: this type is generic over its header, and a generic type cannot hold
  /// a static stored property.
  private static var unfollowBadgeDiameter: CGFloat { 28 }

  init(
    model: NativePodcastShowsModel,
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

  private var modelOrder: [String] { model.shows.map(\.serverItemId) }
  private var isEditingAllowed: Bool {
    if case .loaded = model.state { return true }
    return false
  }
  private var editModeAnimation: Animation? {
    PodcastShowsViewPresentation.editModeAnimation(reduceMotion: reduceMotion)
  }

  var body: some View {
    content
      .itemActionErrorAlert(actions)
      .toolbar {
        if PodcastShowsViewPresentation.editButtonIsAvailable(
          isEditing: session.isEditing, isEditingAllowed: isEditingAllowed)
        {
          ToolbarItem(placement: .topBarTrailing) {
            Button(PodcastShowsViewPresentation.editButtonTitle(isEditing: session.isEditing)) {
              withAnimation(editModeAnimation) {
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
        sourceSwitchGate?.register(source: .followed, prepare: prepareForSourceSwitch)
      }
      .onDisappear { sourceSwitchGate?.unregister(source: .followed) }
      .onChange(of: modelOrder) { _, order in
        session.observe(order: order)
        if NativePodcastShowsViewPresentation.shouldEndEditing(showCount: order.count) {
          session.endEditing()
        }
      }
      .onChange(of: isEditingAllowed) { _, allowed in
        session.syncGate(isEditingAllowed: allowed, order: modelOrder)
      }
      .alert(
        NativePodcastShowsViewPresentation.navigationTitle,
        isPresented: Binding(
          get: { model.actionErrorMessage != nil },
          set: { if $0 == false { model.dismissActionError() } })
      ) {
        Button("OK", role: .cancel) { model.dismissActionError() }
      } message: {
        Text(model.actionErrorMessage ?? "")
      }
      .alert(
        NativePodcastShowsViewPresentation.unfollowConfirmationTitle(
          showTitle: unfollowConfirmation.target?.title ?? ""),
        isPresented: Binding(
          get: { unfollowConfirmation.isPresented },
          set: { if $0 == false { unfollowConfirmation.cancel() } })
      ) {
        Button(NativePodcastShowsViewPresentation.unfollowConfirmLabel, role: .destructive) {
          guard let target = unfollowConfirmation.confirm() else { return }
          Task { await model.unfollow(itemID: target.itemID) }
        }
        Button("Cancel", role: .cancel) { unfollowConfirmation.cancel() }
      } message: {
        Text(NativePodcastShowsViewPresentation.unfollowConfirmationMessage)
      }
      // Reset starts in the toolbar menu, which has collapsed before the question is presented.
      // So use the screen's stable, centred alert host rather than anchoring to that menu.
      .alert(
        NativePodcastShowsViewPresentation.resetConfirmationTitle,
        isPresented: Binding(
          get: { resetConfirmation.isPresented },
          set: { if $0 == false { resetConfirmation.cancel() } })
      ) {
        Button(
          NativePodcastShowsViewPresentation.resetConfirmationConfirmLabel, role: .destructive
        ) {
          resetConfirmation.confirm()
          Task { await model.resetToAlphabetical() }
        }
        Button(NativePodcastShowsViewPresentation.resetConfirmationCancelLabel, role: .cancel) {
          resetConfirmation.cancel()
        }
      } message: {
        Text(NativePodcastShowsViewPresentation.resetConfirmationMessage)
      }
  }

  /// Called synchronously by `PodcastShowsHostView` before it changes the segmented picker. Any
  /// native confirmation must resolve first; otherwise switching would dismiss the alert without
  /// giving the user a chance to confirm or cancel the unfollow/reset.
  private func prepareForSourceSwitch() -> Bool {
    guard resetConfirmation.isPresented == false,
      unfollowConfirmation.isPresented == false
    else { return false }
    withAnimation(editModeAnimation) { session.endEditing() }
    return true
  }

  private var sortMenu: some View {
    Menu {
      Picker(
        NativePodcastShowsViewPresentation.sortMenuLabel,
        selection: Binding(
          get: { model.sortMode.rawValue },
          set: { rawValue in
            guard let mode = NativePodcastShowSortMode(rawValue: rawValue) else { return }
            Task { await model.setSortMode(mode) }
          })
      ) {
        ForEach(NativePodcastShowsViewPresentation.sortModeMenuOrder, id: \.rawValue) { mode in
          Text(NativePodcastShowsViewPresentation.sortModeLabel(mode)).tag(mode.rawValue)
        }
      }
      .pickerStyle(.inline)
      if NativePodcastShowsViewPresentation.resetIsOffered(mode: model.sortMode) {
        Button(role: .destructive) {
          resetConfirmation.request()
        } label: {
          Label(
            NativePodcastShowsViewPresentation.resetMenuActionLabel,
            systemImage: "arrow.counterclockwise")
        }
      }
    } label: {
      Label(NativePodcastShowsViewPresentation.sortMenuLabel, systemImage: "arrow.up.arrow.down")
    }
  }

  private var content: some View {
    // The grid overlays the placeholder on the scroll host: it never becomes scroll content.
    AllShowsGrid(
      shows: model.shows,
      session: $session,
      placeholder: NativePodcastShowsViewPresentation.placeholder(for: model.state),
      coverClient: coverClient,
      paletteService: paletteService,
      playback: playback,
      actions: actions,
      reorderLocked: model.isUnfollowing,
      needsAttention: { model.needsAttention(itemID: $0) },
      editingAction: { show in
        AllShowsEditingAction(
          label: NativePodcastShowsViewPresentation.unfollowAccessibilityLabel(
            showTitle: show.title),
          perform: { requestUnfollow(show) })
      },
      onSelectShow: onSelectShow,
      onSearch: onSearch,
      commit: { order in
        await model.apply(order: order)
        // A rejected write leaves the observed order unchanged, so nothing would resync the
        // working order on its own, so snap it back to the persisted order here.
        if model.actionErrorMessage != nil { session.observe(order: modelOrder) }
      },
      move: { showID, destination in await model.move(showID: showID, to: destination) },
      header: { header },
      editingOverlay: { show in
        if NativePodcastShowsViewPresentation.showsUnfollowControl(isEditing: session.isEditing) {
          unfollowButton(show)
            .padding(WhirrSpacing.xxSmall)
            .transition(
              NativePodcastShowsViewPresentation.editModeEntranceCue(reduceMotion: reduceMotion)
                == .scale
                ? .scale(scale: 0.8).combined(with: .opacity) : .identity)
        }
      })
  }

  private func unfollowButton(_ show: ItemSummary) -> some View {
    let isWorking = model.unfollowingItemID == show.serverItemId

    return Button(role: .destructive) {
      requestUnfollow(show)
    } label: {
      ZStack {
        Circle().fill(.red)
        if isWorking {
          ProgressView()
            .controlSize(.small)
            .tint(.white)
        } else {
          Image(systemName: NativePodcastShowsViewPresentation.unfollowSystemImage)
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: Self.unfollowBadgeDiameter, height: Self.unfollowBadgeDiameter)
      .whirrMinimumHitTarget()
    }
    .buttonStyle(.plain)
    .disabled(model.isUnfollowing)
    .accessibilityLabel(
      NativePodcastShowsViewPresentation.unfollowAccessibilityLabel(showTitle: show.title)
    )
  }

  private func requestUnfollow(_ show: ItemSummary) {
    guard model.isUnfollowing == false else { return }
    unfollowConfirmation.request(itemID: show.serverItemId, title: show.title)
  }
}
