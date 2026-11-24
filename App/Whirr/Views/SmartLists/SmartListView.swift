import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// One smart list's screen: its cover and rules, Play beside the match count, and its episodes,
/// native and server mixed in one order. The rules are the way into the editor. Rows are the Latest
/// Episodes row; Hide is the swipe.
struct SmartListView: View {
  let listID: Int64
  let access: SmartListsAccess
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let downloadStatus: DownloadStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  /// Opens the episode card, carrying the list so the card can say it is playing from it.
  let onSelectEpisode: (String, String, NavigationModel.SmartListContext) -> Void
  let onOpenShow: (ItemSummary) -> Void
  let onSearch: (String) -> Void

  @State private var deferred = DeferredModel<SmartListModel>()
  @State private var homeWashProvider: HomeWashProvider
  @State private var availableWidth: CGFloat = 0
  @State private var editorRequest: SmartListEditorRequest?
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  init(
    listID: Int64,
    access: SmartListsAccess,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    downloadStatus: DownloadStatusStore,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    onSelectEpisode: @escaping (String, String, NavigationModel.SmartListContext) -> Void,
    onOpenShow: @escaping (ItemSummary) -> Void,
    onSearch: @escaping (String) -> Void
  ) {
    self.listID = listID
    self.access = access
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.downloadStatus = downloadStatus
    self.playback = playback
    self.actions = actions
    self.onSelectEpisode = onSelectEpisode
    self.onOpenShow = onOpenShow
    self.onSearch = onSearch
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: HomeMoreView.coverSize, displayScale: 1, artworkRole: .libraryThumbnail))
  }

  private var inset: CGFloat {
    PodcastsViewPresentation.pageColumnInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  private var columnWidth: CGFloat {
    PodcastsViewPresentation.pageColumnWidth(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  var body: some View {
    let model = deferred.resolve { access.makeListModel(listID: listID) }
    content(model)
      .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
      .navigationTitle(
        SmartListsPresentation.listTitle(
          loaded: model.list?.name, listID: listID, lists: access.model.lists)
      )
      .toolbarTitleDisplayMode(.inlineLarge)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: { _, width in
        availableWidth = width
      }
      .smartListEditorSheet(request: $editorRequest)
      .alert(
        SmartListsPresentation.errorTitle,
        isPresented: Binding(
          get: { model.error != nil },
          set: { if $0 == false { model.clearError() } })
      ) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(model.error?.message ?? "")
      }
  }

  @ViewBuilder
  private func content(_ model: SmartListModel) -> some View {
    switch model.state {
    case .loading:
      LoadingStateView(message: SmartListsPresentation.loadingList)
    case .unavailable:
      notice(SmartListsPresentation.unavailable)
    case .missing:
      notice(SmartListsPresentation.missingList)
    case .loaded:
      loaded(model)
    }
  }

  private func notice(_ text: String) -> some View {
    Text(text)
      .font(WhirrTypeToken.subheadline.font)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(WhirrSpacing.large)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func loaded(_ model: SmartListModel) -> some View {
    // Read here, not in each row, so a row is not a dependent of the player.
    let nowPlaying = playback.nowPlayingIdentity
    let isPlaybackActive = playback.isPlaybackIntended
    let context = model.list.map { NavigationModel.SmartListContext(listID: $0.id, name: $0.name) }
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        // Inset by the card's own padding too, so the header shares the rows' artwork column.
        header(model)
          .padding(.horizontal, inset + PodcastEpisodeCardRowMetrics.contentPadding)
          .padding(.bottom, WhirrSpacing.small)

        if model.lastHidden != nil {
          hiddenBanner(model)
            .padding(.horizontal, inset)
            .padding(.bottom, WhirrSpacing.small)
        }

        if model.episodes.isEmpty {
          Text(SmartListsPresentation.emptyList)
            .font(WhirrTypeToken.subheadline.font)
            .foregroundStyle(.secondary)
            .padding(.horizontal, inset)
        } else {
          ForEach(model.episodes) { episode in
            row(
              episode, model: model, context: context, nowPlaying: nowPlaying,
              isPlaybackActive: isPlaybackActive)
          }
          if model.hasMore {
            ProgressView()
              .frame(maxWidth: .infinity)
              .padding(WhirrSpacing.medium)
              .onAppear { model.loadMore() }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .swipeActionsContainerWhereSupported()
    }
    .scrollIndicators(.hidden, axes: .vertical)
    .refreshable { await model.reload() }
  }

  private func header(_ model: SmartListModel) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.medium) {
      if let list = model.list {
        HStack(alignment: .top, spacing: WhirrSpacing.medium) {
          SmartListCoverMosaic(
            episodes: access.model.lists.first { $0.id == listID }?.coverEpisodes ?? [],
            client: coverClient, size: PodcastEpisodeCardRowMetrics.coverSize)
          rules(list)
        }
      }
      HStack(alignment: .center, spacing: WhirrSpacing.medium) {
        SmartListPlayButton(model: model, playback: playback, washProvider: homeWashProvider)
        Spacer(minLength: 0)
        if let count = SmartListsPresentation.matchCountText(model.matchCount) {
          Text(count)
            .font(WhirrTypeToken.subheadline.font)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.updatesFrequently)
        }
      }
    }
  }

  /// The rules as chips, one per rule, ending in the editor's glyph. One button, since every chip
  /// opens the same editor.
  private func rules(_ list: SmartList) -> some View {
    Button {
      editorRequest = SmartListEditorRequest(mode: .edit(listID: listID), template: .blank)
    } label: {
      FlowRowLayout(alignment: .leading, spacing: WhirrSpacing.xSmall, rowSpacing: WhirrSpacing.xSmall) {
        ForEach(SmartListsPresentation.ruleChips(for: list.rules), id: \.self) { rule in
          Text(rule)
            .foregroundStyle(.primary)
            .modifier(RuleChip())
        }
        Image(systemName: "slider.horizontal.3")
          .foregroundStyle(.secondary)
          .modifier(RuleChip())
      }
      .font(WhirrTypeToken.subheadline.font)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(SmartListsPresentation.rulesAccessibilityLabel(for: list.rules))
    .accessibilityHint(SmartListsPresentation.editRulesHint)
    .accessibilityAddTraits(.isButton)
  }

  private func hiddenBanner(_ model: SmartListModel) -> some View {
    HStack {
      Text(SmartListsPresentation.hiddenNotice)
        .font(WhirrTypeToken.subheadline.font)
      Spacer(minLength: WhirrSpacing.small)
      Button(SmartListsPresentation.undoHidden) {
        guard let hidden = model.lastHidden else { return }
        Task { await model.unhide(itemID: hidden.itemID, episodeID: hidden.episodeID) }
      }
    }
    .accessibilityElement(children: .contain)
  }

  private func row(
    _ episode: SmartListEpisode,
    model: SmartListModel,
    context: NavigationModel.SmartListContext?,
    nowPlaying: ListeningIdentity?,
    isPlaybackActive: Bool
  ) -> some View {
    let home = episode.homeEpisode
    return PodcastEpisodeListRow(
      card: PodcastEpisodeCardWithMenu(
        episode: home,
        nowPlaying: nowPlaying,
        isPlaybackActive: isPlaybackActive,
        showsDate: true,
        placement: .smartListEpisodeRow,
        washProvider: homeWashProvider,
        coverClient: coverClient,
        downloadStatus: downloadStatus,
        playback: playback,
        actions: actions,
        onSelect: {
          if let context { onSelectEpisode(episode.itemID, episode.episodeID, context) }
        },
        onStart: { Task { _ = await model.play(episode) } },
        onOpenShow: { onOpenShow(home.showSummary) },
        onSearch: onSearch),
      cardWidth: PodcastsViewPresentation.episodeSingleColumnCardWidth(columnWidth: columnWidth),
      horizontalInset: inset,
      onHide: { Task { await model.hide(episode) } }
    )
    .onAppear {
      if model.hasMore, episode.id == model.episodes.last?.id { model.loadMore() }
    }
  }
}

private struct RuleChip: ViewModifier {
  func body(content: Content) -> some View {
    content
      .lineLimit(1)
      .padding(.horizontal, WhirrSpacing.small)
      .padding(.vertical, WhirrSpacing.xxSmall)
      .background(.quaternary, in: .capsule)
  }
}
