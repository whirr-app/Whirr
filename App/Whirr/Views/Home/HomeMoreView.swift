import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI

nonisolated enum HomeMoreEditorialRowPresentation {
  struct Text: Equatable {
    let eyebrow: String?
    let subtitle: String?
  }

  static func text(from presentation: HomeMoreItemRowPresentation) -> Text {
    Text(eyebrow: presentation.subtitle, subtitle: nil)
  }
}

/// A bounded push from Home. It never becomes the Library tab: the section and filter that were
/// visible on Home determine the local projection shown here.
struct HomeMoreView: View {
  /// Larger than the 44pt browse thumbnail: these rows carry three or four lines of text, and a
  /// touch-target-sized cover left the artwork stranded beside them.
  static let coverSize: CGFloat = 56

  @State private var deferredModel = DeferredModel<HomeMoreModel>()
  @State var selectionEditMode: EditMode = .inactive
  @State var selection = BatchSelectionController<String, HomeMoreSelectionAction>()
  @State private var homeWashProvider: HomeWashProvider
  @State private var bookZoomOccurrenceID = UUID()
  @Environment(\.bookZoomTransitionContext) private var bookZoomTransition
  @AppStorage(HomeSectionVisibility.continueCardOpenOnTapStorageKey)
  private var opensContinueCardImmediately = true

  let section: HomeMoreSection
  let filter: MediaFilter
  let makeModel: () -> HomeMoreModel
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let downloadStatus: DownloadStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let onSelectItem: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  /// The listening counterpart of `onPresentReader`, used when the reader's Continue Listening
  /// tap preference is immediate playback.
  let onResumeListening: (String, String?) -> Void
  /// Downloaded podcast rows open the show with its Downloaded filter selected, matching the
  /// Downloaded shelf on Home rather than opening the show's unfiltered episode list. The summary
  /// is retained so the show can paint its first frame without rediscovering metadata.
  let onSelectDownloadedPodcast: (ItemSummary) -> Void
  /// The podcast episode rows open the episode card, not the show.
  let onSelectEpisode: (String, String) -> Void
  let onSearch: (String) -> Void

  init(
    section: HomeMoreSection,
    filter: MediaFilter,
    makeModel: @escaping () -> HomeMoreModel,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    downloadStatus: DownloadStatusStore,
    actions: ItemActionsModel,
    playback: PlaybackModel,
    onSelectItem: @escaping (ItemSummary) -> Void,
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void = { _, _, _ in },
    onResumeListening: @escaping (String, String?) -> Void = { _, _ in },
    onSelectDownloadedPodcast: @escaping (ItemSummary) -> Void,
    onSelectEpisode: @escaping (String, String) -> Void,
    onSearch: @escaping (String) -> Void
  ) {
    self.section = section
    self.filter = filter
    self.makeModel = makeModel
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.downloadStatus = downloadStatus
    self.actions = actions
    self.playback = playback
    self.onSelectItem = onSelectItem
    self.onPresentReader = onPresentReader
    self.onResumeListening = onResumeListening
    self.onSelectDownloadedPodcast = onSelectDownloadedPodcast
    self.onSelectEpisode = onSelectEpisode
    self.onSearch = onSearch
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: Self.coverSize, displayScale: 1, artworkRole: .libraryThumbnail))
  }

  var model: HomeMoreModel {
    deferredModel.resolve(makeModel)
  }

  private var offersSelection: Bool {
    HomeMoreSelectionPolicy.offersSelection(section: section)
  }

  var body: some View {
    content
      .disabled(offersSelection && selection.isPerforming)
      .selectionChrome(
        isSelecting: offersSelection && selectionEditMode.isEditing,
        selectionTitle: selectionTitle,
        title: HomeCopy.moreTitle(section: section, filter: filter),
        titleDisplayMode: .inline
      )
      .toolbar { selectionToolbar }
      .toolbar(
        offersSelection && selectionEditMode.isEditing ? .hidden : .automatic,
        for: .tabBar
      )
      .hidesPlayerAccessory(whileSelecting: offersSelection && selectionEditMode.isEditing)
      // Withheld from the five sections that do not select, so nothing about their rows changes:
      // an edit mode in the environment is what a row consults to decide it is being selected.
      .environment(\.editMode, offersSelection ? $selectionEditMode : nil)
      .navigationBarBackButtonHidden(offersSelection && selectionEditMode.isEditing)
      .onChange(of: selectionEditMode) { _, mode in
        if offersSelection && !mode.isEditing { selection.selected.removeAll() }
      }
      .onChange(of: visibleItemIDs) { _, ids in
        if offersSelection { selection.selected.formIntersection(ids) }
      }
      .refreshable {
        if !offersSelection || !selectionEditMode.isEditing {
          await model.refresh()
        }
      }
      .itemActionErrorAlert(
        actions,
        isSuppressed: offersSelection && selection.isPerforming
      )
      .alert(
        selectionConfirmationTitle,
        isPresented: Binding(
          get: { selection.pending != nil }, set: { _ in }
        )
      ) {
        Button("Cancel", role: .cancel) { selection.cancelPending() }
        Button(
          selectionConfirmationTitle,
          role: selection.pending?.action == .removeDownload ? .destructive : nil
        ) {
          selection.confirmPending { performSelectionAction($0, ids: $1) }
        }
      } message: {
        Text(selectionConfirmationMessage)
      }
  }

  private var content: some View {
    return List(
      selection: offersSelection && selectionEditMode.isEditing ? $selection.selected : nil
    ) {
      if statePlaceholder == nil {
        loadedRows
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .primaryScrollEdgeEffect(role: offersSelection && selectionEditMode.isEditing ? .selecting : .titled)
    .selectionMarkTint(isSelecting: offersSelection && selectionEditMode.isEditing)
    // An overlay, not a row: the placeholder must never become scroll content under a large title.
    .overlay {
      if let placeholder = statePlaceholder {
        placeholderView(placeholder)
          .allowsHitTesting(placeholder.allowsHitTesting)
      }
    }
  }

  private var statePlaceholder: HomeMoreViewPresentation.Placeholder? {
    HomeMoreViewPresentation.placeholder(for: model.state)
  }

  @ViewBuilder
  private func placeholderView(
    _ placeholder: HomeMoreViewPresentation.Placeholder
  ) -> some View {
    switch placeholder {
    case .loading:
      LoadingStateView(message: "Loading…")
    case .empty:
      EmptyStateView(
        title: HomeCopy.moreTitle(section: section, filter: filter),
        message: HomeCopy.moreEmptyMessage(section: section, filter: filter),
        systemImage: emptySystemImage)
    }
  }

  @ViewBuilder
  private var loadedRows: some View {
    if model.podcastEpisodes.isEmpty == false {
      podcastListRows
    } else {
      itemListRows
    }
  }

  private var emptySystemImage: String {
    if section == .newEpisodes || (section == .recentlyAdded && filter == .podcasts) {
      return "antenna.radiowaves.left.and.right"
    }
    if let category = filter.category {
      return HomeViewPresentation.badgeKind(for: category).symbolName
    }
    return "books.vertical"
  }

  @ViewBuilder
  private var itemListRows: some View {
    if section == .recentlyAdded {
      listCaption(HomeCopy.moreRecentWindow)
    }
    if section == .downloaded, let bytes = model.accountStorageBytes {
      listCaption(HomeCopy.downloadedStorageAmount(bytes: bytes)).monospacedDigit()
    }

    // Resolved once for the page, like a shelf resolves it for its strip.
    let mixesSources = HomeViewPresentation.shelfMixesPodcastSources(items: model.items)
    let nowPlaying = playback.nowPlayingIdentity
    ForEach(model.items) { item in
      itemRow(item, surfaceMixesSources: mixesSources, nowPlaying: nowPlaying)
    }
  }

  /// The screen's leading blurb. Sits closer to the nav bar and to the first row than a default
  /// list row would, so it reads as a caption for the list rather than as a row of its own.
  private func listCaption(_ text: String) -> some View {
    Text(text)
      .font(WhirrTypeToken.caption.font)
      .foregroundStyle(WhirrColorToken.textSecondary.color)
      .listRowSeparator(.hidden)
      .listRowInsets(
        EdgeInsets(
          top: WhirrSpacing.xxSmall, leading: WhirrSpacing.medium, bottom: WhirrSpacing.xSmall,
          trailing: WhirrSpacing.medium))
  }

  /// The row's progress at the displayed position. Reading progress has no playhead, so a
  /// Continue Reading row keeps the presentation it was given.
  private func liveProgress(
    of item: HomeItem, presentation: HomeMoreItemRowPresentation, surfaceMixesSources: Bool
  ) -> HomeMoreItemRowPresentation {
    guard section != .continueReading else { return presentation }
    return HomeMoreItemRowPresentation(
      item: item, section: section,
      playbackRate: playback.effectiveRate(for: item.serverItemId),
      surfaceMixesSources: surfaceMixesSources,
      progressSeconds: playback.listPositionSeconds(
        itemID: item.serverItemId, episodeID: item.episodeID, persisted: item.progressSeconds))
  }

  /// Laid out like `podcastRow` below rather than like a browse row: the title runs the full width
  /// (so it wraps twice, not five times), and the progress bar sits under the text instead of
  /// competing with it for horizontal space.
  private func itemRow(
    _ item: HomeItem, surfaceMixesSources: Bool, nowPlaying: ListeningIdentity?
  ) -> some View {
    let isSelecting = offersSelection && selectionEditMode.isEditing
    let presentation = HomeMoreItemRowPresentation(
      item: item, section: section,
      playbackRate: playback.effectiveRate(for: item.serverItemId),
      surfaceMixesSources: surfaceMixesSources)
    let rowText = HomeMoreEditorialRowPresentation.text(from: presentation)
    let storageText = model.itemStorageBytes[item.serverItemId].map(formattedBytes)
    let row = WideCompactCard(
      item: item.washSubject,
      provider: homeWashProvider,
      coverClient: coverClient,
      title: presentation.title,
      subtitle: rowText.subtitle,
      metadata: [presentation.metadataText, storageText].compactMap { $0 }.joined(separator: " · "),
      accessibilityLabel: [presentation.accessibilityLabel, storageText]
        .compactMap { $0 }
        .joined(separator: ", "),
      eyebrow: rowText.eyebrow,
      coverTitle: item.title,
      coverAuthor: item.author,
      inlineContent: {
        if section != .downloaded {
          if presentation.isFinished {
            FinishedRowBadge(itemID: item.serverItemId, isCompact: true)
          }
          OfflineBadgeRow(
            itemID: item.serverItemId, downloadStatus: downloadStatus, isCompact: true)
        }
      },
      trailingContent: {
        if presentation.progressText != nil || presentation.progressFraction != nil {
          // Resolved here, inside the card's body, so the playing title's bar follows the
          // playhead without invalidating this list. Whether the bar shows stays persisted.
          let progress = liveProgress(of: item, presentation: presentation, surfaceMixesSources: surfaceMixesSources)
          VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
            if let fraction = progress.progressFraction {
              PlaybackProgressBar(fraction: fraction)
            }
            if let progressText = progress.progressText {
              Text(progressText)
                .font(WhirrTypeToken.caption2.font)
                .foregroundStyle(WashInk.secondary)
                .monospacedDigit()
            }
          }
          .padding(.top, WhirrSpacing.xxSmall)
        }
      },
      bookZoomSource: bookZoomTransition?.source(
        item: item.itemSummary,
        occurrence: "home-more-\(bookZoomOccurrenceID.uuidString)/\(section.rawValue)/\(item.serverItemId)")
    ) { summaryRow in
      if isSelecting {
        summaryRow.contentShape(Rectangle())
      } else {
        Button {
          open(item)
        } label: {
          summaryRow
        }
        .buttonStyle(.plain)
      }
    }
    .accessibilityIdentifier(HomeAccessibilityID.moreItemRowPrefix + item.serverItemId)

    let rowWithAccessibilityHint = Group {
      if let accessibilityHint = HomeCopy.continueCardHint(
        for: item.category, in: section,
        opensContinueCardImmediately: opensContinueCardImmediately)
      {
        row.accessibilityHint(accessibilityHint)
      } else {
        row
      }
    }

    return Group {
      if !isSelecting, ItemContextMenuAvailability.offersMenu(for: item.category) {
        rowWithAccessibilityHint.itemContextMenu(
          ItemMenuSubject(
            item: item,
            usesEbookProgress: HomeMoreSelectionPolicy.usesEbookProgress(for: item, in: section),
            coverClient: coverClient,
            playback: playback,
            actions: actions),
          placement: .homeMoreRow,
          // The context-menu Open action always means the item's detail page. Continue Listening
          // and Continue Reading keep their direct playback/reader behavior only for the primary
          // row tap, so they must not route this action through `HomeCardSelection.destination`.
          onOpen: { openDetail(item) },
          onRead: {
            onPresentReader(item.serverItemId, item.title, item.category)
          },
          onSearch: onSearch)
      } else {
        rowWithAccessibilityHint
      }
    }
    .itemSwipeActions(
      ItemSwipeSubject(item),
      prefersReading: section == .continueReading,
      isSelecting: isSelecting,
      nowPlaying: nowPlaying,
      playback: playback,
      actions: actions,
      onRead: { onPresentReader(item.serverItemId, item.title, item.category) }
    )
    .tag(item.serverItemId)
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func open(_ item: HomeItem) {
    let destination = HomeCardSelection.destination(
      for: item, in: section,
      opensContinueCardImmediately: opensContinueCardImmediately)
    if case .item(let summary) = destination,
      bookZoomTransition?.selectBook(
        summary,
        occurrence: "home-more-\(bookZoomOccurrenceID.uuidString)/\(section.rawValue)/\(item.serverItemId)",
        artworkRole: .libraryThumbnail, displaySize: Self.coverSize) == true
    {
      return
    }
    HomeShelfCardActions(
      onSelectItem: onSelectItem,
      onPresentReader: onPresentReader,
      onResumeListening: onResumeListening,
      onSelectDownloadedPodcast: onSelectDownloadedPodcast,
      onSelectEpisode: onSelectEpisode,
      onSearch: onSearch
    ).perform(destination)
  }

  private func openDetail(_ item: HomeItem) {
    guard
      bookZoomTransition?.selectBook(
        item.itemSummary,
        occurrence: "home-more-\(bookZoomOccurrenceID.uuidString)/\(section.rawValue)/\(item.serverItemId)",
        artworkRole: .libraryThumbnail, displaySize: Self.coverSize) != true
    else { return }
    onSelectItem(item.itemSummary)
  }

  private var podcastListRows: some View {
    let nowPlaying = playback.nowPlayingIdentity
    let isPlaybackActive = playback.isPlaybackIntended
    return Group {
      listCaption(HomeCopy.moreRecentWindow)

      ForEach(model.podcastEpisodes) { episode in
        podcastRow(
          episode, nowPlaying: nowPlaying, isPlaybackActive: isPlaybackActive)
      }
    }
  }

  private func podcastRow(
    _ episode: HomePodcastEpisode,
    nowPlaying: ListeningIdentity?,
    isPlaybackActive: Bool
  ) -> some View {
    let isPlaying = PodcastsViewPresentation.isPlaying(
      episode: episode, nowPlaying: nowPlaying, isPlaybackActive: isPlaybackActive)
    let row = WideCompactCard(
      episode: episode,
      provider: homeWashProvider,
      coverClient: coverClient,
      downloadStatus: downloadStatus,
      playback: playback,
      isPlaying: isPlaying,
      onSelect: {
        // This row's tap opens the episode itself, not the show.
        onSelectEpisode(episode.itemID, episode.episodeID)
      },
      onPlay: {
        if isPlaying {
          playback.togglePlayPause(itemID: episode.itemID, episodeID: episode.episodeID)
        } else {
          Task { await playback.start(itemID: episode.itemID, episodeID: episode.episodeID) }
        }
      }
    )
    .accessibilityHint(PodcastsViewPresentation.episodeRowAccessibilityHint)
    .accessibilityIdentifier(HomeAccessibilityID.morePodcastRowPrefix + episode.id)
    return row.itemContextMenu(
      ItemMenuSubject(
        episode: episode, coverClient: coverClient, playback: playback, actions: actions),
      placement: .homeMoreRow,
      onOpen: {
        onSelectItem(episode.showSummary)
      },
      onSearch: onSearch
    )
    .podcastEpisodeSwipeActions(
      episode: episode, nowPlaying: nowPlaying, playback: playback, actions: actions)
  }
}
