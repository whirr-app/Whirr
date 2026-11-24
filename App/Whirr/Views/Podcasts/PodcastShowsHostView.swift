import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The combined all-shows destination: owns the title and source picker; the two children keep
/// their source-specific edit, sort, alert and refresh. The originating route is carried in so
/// deep links open on their usual tab.
///
/// The picker is rendered by the live child as its scroll view's first row, not as a sibling
/// above: otherwise nothing scrolls under the navigation bar and the large title cannot collapse.
struct PodcastShowsHostView: View {
  @Bindable var model: PodcastShowsModel
  @Bindable var nativeModel: NativePodcastShowsModel
  let originatingRoute: NavigationModel.Route
  let nativeSubscriptionsEnabled: Bool
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelectShow: (ItemSummary) -> Void
  let onSearch: (String) -> Void
  let onNativeOriginDisabled: () -> Void

  @State private var selectedSource: PodcastShowsHostViewPresentation.Source
  @State private var sourceSwitchGate: PodcastShowsSourceSwitchGate

  init(
    model: PodcastShowsModel,
    nativeModel: NativePodcastShowsModel,
    originatingRoute: NavigationModel.Route,
    nativeSubscriptionsEnabled: Bool,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    onSelectShow: @escaping (ItemSummary) -> Void,
    onSearch: @escaping (String) -> Void,
    onNativeOriginDisabled: @escaping () -> Void = {}
  ) {
    _model = Bindable(model)
    _nativeModel = Bindable(nativeModel)
    self.originatingRoute = originatingRoute
    self.nativeSubscriptionsEnabled = nativeSubscriptionsEnabled
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.playback = playback
    self.actions = actions
    self.onSelectShow = onSelectShow
    self.onSearch = onSearch
    self.onNativeOriginDisabled = onNativeOriginDisabled
    _selectedSource = State(
      initialValue: PodcastShowsHostViewPresentation.source(
        for: originatingRoute, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled))
    _sourceSwitchGate = State(initialValue: PodcastShowsSourceSwitchGate())
  }

  var body: some View {
    Group {
      switch selectedSource {
      case .followed:
        NativePodcastShowsView(
          model: nativeModel,
          coverClient: coverClient,
          paletteService: paletteService,
          playback: playback,
          actions: actions,
          onSelectShow: onSelectShow,
          onSearch: onSearch,
          sourceSwitchGate: sourceSwitchGate,
          header: { sourcePicker })
      case .server:
        PodcastShowsView(
          model: model,
          coverClient: coverClient,
          paletteService: paletteService,
          playback: playback,
          actions: actions,
          onSelectShow: onSelectShow,
          onSearch: onSearch,
          sourceSwitchGate: sourceSwitchGate,
          header: { sourcePicker })
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .navigationTitle(PodcastShowsHostViewPresentation.navigationTitle)
    .onChange(of: originatingRoute) { _, route in
      // A deep-link restore can replace the path while SwiftUI keeps this destination's
      // structural identity. Re-apply the route's first tab in that case; a user's picker choice
      // stays local until the originating route changes.
      selectedSource = PodcastShowsHostViewPresentation.source(
        for: route, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled)
    }
    .onChange(of: nativeSubscriptionsEnabled) { _, enabled in
      guard enabled == false else { return }
      if PodcastShowsHostViewPresentation.isNativeOriginating(originatingRoute) {
        // RootModel normally truncates this route at the same observation edge. The callback
        // keeps the host correct during the one render transaction before that edge.
        onNativeOriginDisabled()
      } else if selectedSource == .followed {
        // A server-origin route survives native disable, but its picker cannot stay on a source
        // that no longer exists. The ordinary gate still gets first refusal, including alerts.
        requestSource(.server)
      }
    }
  }

  private var sourcePicker: some View {
    let sources = PodcastShowsHostViewPresentation.Source.allCases
    let disabledIndices = Set(
      sources.indices.filter {
        PodcastShowsHostViewPresentation.sourceIsAvailable(
          sources[$0], nativeSubscriptionsEnabled: nativeSubscriptionsEnabled) == false
      })

    return MediaFilterPicker(
      title: PodcastShowsHostViewPresentation.sourcePickerLabel,
      labels: sources.map(\.label),
      selectedIndex: sources.firstIndex(of: selectedSource) ?? 0,
      style: .chips,
      selectionTint: nil,
      disabledIndices: disabledIndices,
      onSelect: { index in
        guard sources.indices.contains(index) else { return }
        requestSource(sources[index])
      }
    )
    .padding(.bottom, HomePodcastsBrowseLayout.filterBottomSpacing)
    .accessibilityLabel(PodcastShowsHostViewPresentation.sourcePickerLabel)
  }

  private func requestSource(_ source: PodcastShowsHostViewPresentation.Source) {
    guard source != selectedSource else { return }
    guard
      PodcastShowsHostViewPresentation.sourceIsAvailable(
        source, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled)
    else { return }
    guard sourceSwitchGate.prepare(source: selectedSource) else { return }
    selectedSource = source
  }
}
