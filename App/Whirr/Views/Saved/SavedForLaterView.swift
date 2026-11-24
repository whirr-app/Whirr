import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI

/// The complete Saved for Later destination. It keeps the mixed saved-at ordering from the local
/// projection intact so books and podcast episodes remain one shelf rather than two lists.
struct SavedForLaterView: View {
  static let coverSize: CGFloat = 56

  @State private var deferredModel = DeferredModel<SavedForLaterListModel>()
  @State private var homeWashProvider: HomeWashProvider
  @State private var editMode: EditMode = .inactive
  @State private var selection = BatchSelectionController<SavedShelfIdentity, SavedForLaterSelectionAction>()
  /// The zoom transition's per-appearance namespace, and the context that owns it.
  @State private var bookZoomOccurrenceID = UUID()
  @Environment(\.bookZoomTransitionContext) private var bookZoomTransition
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  let makeModel: () -> SavedForLaterListModel
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let downloadStatus: DownloadStatusStore
  let finishedStatus: FinishedStatusStore
  let actions: ItemActionsModel
  let playback: PlaybackModel
  let onSelectItem: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSelectEpisode: (String, String) -> Void
  let onSearch: (String) -> Void

  init(
    makeModel: @escaping () -> SavedForLaterListModel,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    downloadStatus: DownloadStatusStore,
    finishedStatus: FinishedStatusStore,
    actions: ItemActionsModel,
    playback: PlaybackModel,
    onSelectItem: @escaping (ItemSummary) -> Void,
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void,
    onSelectEpisode: @escaping (String, String) -> Void,
    onSearch: @escaping (String) -> Void
  ) {
    self.makeModel = makeModel
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.downloadStatus = downloadStatus
    self.finishedStatus = finishedStatus
    self.actions = actions
    self.playback = playback
    self.onSelectItem = onSelectItem
    self.onPresentReader = onPresentReader
    self.onSelectEpisode = onSelectEpisode
    self.onSearch = onSearch
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: Self.coverSize, displayScale: 1, artworkRole: .libraryThumbnail))
  }

  private var model: SavedForLaterListModel {
    deferredModel.resolve(makeModel)
  }

  var body: some View {
    content
      .disabled(selection.isPerforming)
      .selectionChrome(
        isSelecting: editMode.isEditing,
        selectionTitle: SelectionChromePresentation.title(
          screen: .savedForLater, selectedCount: selection.selected.count,
          isWorking: selection.isPerforming),
        title: HomeCopy.savedForLaterTitle,
        titleDisplayMode: .inline
      )
      // Local-only projection, so there is no server refresh to trigger. Suppression keeps
      // intermediate failures and per-item banners inside the captured batch.
      .itemActionErrorAlert(actions, isSuppressed: selection.isPerforming)
      .toolbar {
        screenToolbar
      }
      .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
      .hidesPlayerAccessory(whileSelecting: editMode.isEditing)
      .environment(\.editMode, $editMode)
      .navigationBarBackButtonHidden(editMode.isEditing)
      .onChange(of: editMode) { _, mode in if !mode.isEditing { selection.selected.removeAll() } }
      .onChange(of: visibleSavedIDs) { _, ids in selection.selected.formIntersection(ids) }
      .alert(
        selection.pending?.action.title ?? "Selected Items",
        isPresented: Binding(
          get: { selection.pending != nil }, set: { _ in }
        )
      ) {
        Button("Cancel", role: .cancel) { selection.cancelPending() }
        Button(
          selection.pending?.action.title ?? "Confirm",
          role: selection.pending?.action == .resetProgress ? nil : .destructive
        ) {
          selection.confirmPending { performSelectionAction($0, ids: $1) }
        }
      } message: {
        Text(selectionConfirmationMessage)
      }
  }

  /// The selection toolbar, or its entry button outside selection. Split out of `body` so the
  /// chrome chain stays one screenful.
  @ToolbarContentBuilder
  private var screenToolbar: some ToolbarContent {
    if editMode.isEditing {
      SelectionToolbar(
        screen: .savedForLater, selectedCount: selection.selected.count,
        isEverythingSelected: selection.selected == visibleSavedIDs,
        isWorking: selection.isPerforming, isSelectAllEnabled: !visibleSavedIDs.isEmpty,
        onToggleSelectAll: { selection.selected = selection.selected == visibleSavedIDs ? [] : visibleSavedIDs },
        download: {
          SelectionDownloadControl(
            hasFormatChoice: selectedEntries(for: .download).contains(where: {
              SavedForLaterSelectionPolicy.capability(for: $0)?.offersFormatChoice ?? false
            }),
            isDisabled: selectionActionIsDisabled(.download),
            accessibilityID: SavedAccessibilityID.selectionDownload,
            request: requestDownload)
        },
        markAsFinished: {
          Button(MediaActionCopy.markAsFinished.title, systemImage: MediaActionCopy.markAsFinished.systemImage) {
            requestSelectionAction(.markAsFinished)
          }
          .disabled(selectionActionIsDisabled(.markAsFinished))
        },
        more: {
          Menu {
            Button(MediaActionCopy.resetProgress.title, systemImage: MediaActionCopy.resetProgress.systemImage) {
              requestSelectionAction(.resetProgress)
            }
            .disabled(selectionActionIsDisabled(.resetProgress))
            Button(MediaActionCopy.addToUpNext.title, systemImage: MediaActionCopy.addToUpNext.systemImage) {
              requestSelectionAction(.addToUpNext)
            }
            .disabled(selectionActionIsDisabled(.addToUpNext))
            Divider()
            Button(
              MediaActionCopy.removeDownloads.title, systemImage: MediaActionCopy.removeDownloads.systemImage,
              role: .destructive
            ) {
              requestSelectionAction(.removeDownload)
            }
            .disabled(selectionActionIsDisabled(.removeDownload))
          } label: {
            Label("Saved Actions", systemImage: "ellipsis.circle")
          }
          .disabled(selection.isPerforming || selection.selected.isEmpty)
          .accessibilityIdentifier(SavedAccessibilityID.selectionActions)
        },
        destructive: {
          Button(
            MediaActionCopy.removeSelectionFromSaved.title,
            systemImage: MediaActionCopy.removeSelectionFromSaved.systemImage, role: .destructive
          ) {
            requestSelectionAction(.removeFromSaved)
          }
          .disabled(selectionActionIsDisabled(.removeFromSaved))
          .accessibilityIdentifier(SavedAccessibilityID.selectionRemove)
        })
    } else {
      ToolbarItem(placement: .topBarTrailing) {
        SelectionEntryButton(screen: .savedForLater, isEnabled: !model.entries.isEmpty) {
          editMode = .active
        }
      }
    }
  }

  private var visibleSavedIDs: Set<SavedShelfIdentity> { Set(model.entries.map(\.identity)) }

  private var selectionConfirmationMessage: String {
    let count = selection.pending?.ids.count ?? 0
    switch selection.pending?.action {
    case .removeDownload: return "Remove downloads for \(count) selected items from this device?"
    case .resetProgress: return "Reset progress for \(count) selected items to the beginning?"
    default: return "Remove \(count) selected items from Saved for Later?"
    }
  }

  private func selectionActionIsDisabled(_ action: SavedForLaterSelectionAction) -> Bool {
    selection.isPerforming || selectedEntries(for: action).isEmpty
  }

  private func selectedEntries(
    for action: SavedForLaterSelectionAction, ids: Set<SavedShelfIdentity>? = nil
  ) -> [SavedShelfItem] {
    SavedForLaterSelectionPolicy.selectedEntries(model.entries, ids: ids ?? selection.selected).filter { entry in
      let parts = entry.identity
      return SavedForLaterSelectionPolicy.accepts(
        action, entry: entry, deviceAction: actions.downloadAction(for: parts.itemID, episodeID: parts.episodeID),
        nowPlaying: playback.nowPlayingIdentity,
        itemPlaybackStatus: finishedStatus.playbackStatus(parts.itemID))
    }
  }

  private func requestSelectionAction(_ action: SavedForLaterSelectionAction) {
    selection.request(
      action, eligibleIDs: Set(selectedEntries(for: action).map(\.identity)),
      requiresConfirmation: action == .removeFromSaved || action == .removeDownload || action == .resetProgress,
      run: { performSelectionAction($0, ids: $1) })
  }

  private func performSelectionAction(
    _ action: SavedForLaterSelectionAction, ids: Set<SavedShelfIdentity>, format: ItemDownloadFormat? = nil
  ) {
    selection.perform(
      targets: {
        selectedEntries(for: action, ids: ids).compactMap { entry -> (SavedShelfIdentity, ItemBatchTarget)? in
          let downloadFormat = SavedForLaterSelectionPolicy.downloadFormat(for: entry, requested: format)
          guard action != .download || downloadFormat != nil else { return nil }
          let target = ItemBatchTarget(
            itemID: entry.identity.itemID, episodeID: entry.identity.episodeID, category: entry.category,
            durationSeconds: entry.episode?.durationSeconds ?? entry.itemSummary?.durationSeconds,
            downloadFormat: downloadFormat)
          return (entry.identity, target)
        }
      },
      dismissError: actions.dismissActionError,
      batch: { await actions.performBatch(action.batchAction, on: $0, playback: playback).succeeded },
      exitEditMode: { withAnimation { editMode = .inactive } })
  }

  private func requestDownload(_ format: ItemDownloadFormat?) {
    let ids = Set(selectedEntries(for: .download).map(\.identity))
    performSelectionAction(.download, ids: ids, format: format)
  }

  private var content: some View {
    List(selection: editMode.isEditing ? $selection.selected : nil) {
      // Withdrawn while selecting: selection is already a modal state (the tab bar, back button
      // and player accessory all go), and re-filtering mid-selection would drop whatever left the
      // visible set with no way to get it back.
      if !editMode.isEditing {
        filterPicker
          .plainListRow(top: HomePodcastsBrowseLayout.filterRowTopSpacing)
      }
      if model.state == .loaded {
        ForEach(model.entries) { entry in
          savedRow(entry)
        }
        .transition(.opacity)
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .primaryScrollEdgeEffect(role: editMode.isEditing ? .selecting : .titled)
    .selectionMarkTint(isSelecting: editMode.isEditing)
    .overlay {
      placeholderView
        .allowsHitTesting(false)
    }
  }

  /// Saved for Later's own media-type filter. Seeded from whatever filter opened the page, so a
  /// filtered Home lands on the same contents, then the reader's own. The shelf spans media types
  /// and needs narrowing in place, not a trip back to Home.
  private var filterPicker: some View {
    MediaFilterPicker(
      title: MediaFilterCopy.title,
      labels: MediaFilter.allCases.map(MediaFilterCopy.label(for:)),
      selectedIndex: MediaFilter.allCases.firstIndex(of: model.filter) ?? 0,
      style: .chips,
      onSelect: { index in
        guard MediaFilter.allCases.indices.contains(index) else { return }
        withAnimation(PodcastsViewPresentation.filterChangeMotion(reduceMotion: reduceMotion)) {
          model.filter = MediaFilter.allCases[index]
        }
      }
    )
    .padding(.bottom, HomePodcastsBrowseLayout.filterBottomSpacing)
    .accessibilityIdentifier(SavedAccessibilityID.filterPicker)
  }

  @ViewBuilder
  private var placeholderView: some View {
    switch model.state {
    case .loading:
      LoadingStateView(message: "Loading…")
    case .empty:
      EmptyStateView(
        title: HomeCopy.savedForLaterEmptyTitle(for: model.filter),
        message: HomeCopy.savedForLaterEmpty(for: model.filter),
        systemImage: "bookmark")
    case .loaded:
      EmptyView()
    }
  }

  /// Selecting is a state of each row, not a different row. Entering edit mode takes the row's
  /// controls away (open button, play button, swipes, menu) and leaves the card as it was, so
  /// nothing reflows and no metadata disappears. Every row is tagged whether or not a selection
  /// is running; the tag is inert while `List(selection:)` is nil.
  @ViewBuilder private func savedRow(_ entry: SavedShelfItem) -> some View {
    let isSelecting = editMode.isEditing
    Group {
      if let episode = entry.episode, !entry.isUnavailable {
        episodeRow(entry, episode: episode, isSelecting: isSelecting)
      } else if let summary = entry.itemSummary, entry.episode == nil, !entry.isUnavailable {
        itemRow(entry, summary: summary, isSelecting: isSelecting)
      } else {
        unavailableRow(entry, isSelecting: isSelecting)
      }
    }
    .tag(entry.identity)
  }

  private func itemRow(
    _ entry: SavedShelfItem, summary: ItemSummary, isSelecting: Bool
  ) -> some View {
    let title = entry.subjectTitle.isEmpty ? summary.title : entry.subjectTitle
    let subtitle = entry.contextTitle ?? summary.author
    let durationText = ItemDetailDurationPresentation.durationText(
      category: entry.category, durationSeconds: summary.durationSeconds)
    let metadata = [
      HomeRowPresentation.badgeLabel(for: entry.category),
      durationText,
    ].compactMap { $0 }.joined(separator: " · ")
    let row = WideCompactCard(
      item: summary.washSubject,
      provider: homeWashProvider,
      coverClient: coverClient,
      title: title,
      subtitle: subtitle,
      metadata: metadata,
      accessibilityLabel: [title, subtitle, metadata].compactMap { $0 }.joined(separator: ", "),
      coverAuthor: summary.author,
      inlineContent: {
        OfflineBadgeRow(
          itemID: summary.serverItemId, downloadStatus: downloadStatus, isCompact: true)
      },
      trailingContent: {
        EmptyView()
      },
      bookZoomSource: bookZoomTransition?.source(
        item: summary,
        occurrence: "saved-\(bookZoomOccurrenceID.uuidString)/\(summary.serverItemId)")
    ) { summaryRow in
      // While selecting, the list cell owns the tap. A button over the card would swallow it,
      // and there is nothing to zoom to because the tap ticks a checkbox.
      if isSelecting {
        summaryRow.contentShape(Rectangle())
      } else {
        Button {
          if bookZoomTransition?.selectBook(
            summary,
            occurrence: "saved-\(bookZoomOccurrenceID.uuidString)/\(summary.serverItemId)",
            artworkRole: .libraryThumbnail, displaySize: Self.coverSize) != true
          {
            onSelectItem(summary)
          }
        } label: {
          summaryRow
        }
        .buttonStyle(.plain)
      }
    }
    .accessibilityIdentifier(HomeAccessibilityID.moreItemRowPrefix + summary.serverItemId)

    let menuRow = Group {
      if !isSelecting, ItemContextMenuAvailability.offersMenu(for: entry.category) {
        row.itemContextMenu(
          ItemMenuSubject(
            summary: summary, title: title, category: entry.category,
            coverClient: coverClient, source: nil, revision: summary.artworkRevision,
            playback: playback, actions: actions),
          placement: .savedForLaterRow,
          onOpen: {
            if let bookZoomTransition,
              bookZoomTransition.selectBook(
                summary,
                occurrence: "saved-\(bookZoomOccurrenceID.uuidString)/\(summary.serverItemId)",
                artworkRole: .libraryThumbnail, displaySize: Self.coverSize)
            {
            } else {
              onSelectItem(summary)
            }
          },
          onRead: {
            onPresentReader(summary.serverItemId, summary.title, entry.category)
          },
          onSearch: onSearch)
      } else {
        row
      }
    }
    return savedSwipe(
      menuRow, for: entry,
      capability: ItemMediaCapability.derive(
        category: entry.category, hasReadableEbook: summary.hasReadableEbook),
      isSelecting: isSelecting,
      carriesMenuTwin: !ItemContextMenuAvailability.offersMenu(for: entry.category))
  }

  private func episodeRow(
    _ entry: SavedShelfItem, episode: HomePodcastEpisode, isSelecting: Bool
  ) -> some View {
    let isPlaying = PodcastsViewPresentation.isPlaying(
      episode: episode,
      nowPlaying: playback.nowPlayingIdentity,
      isPlaybackActive: playback.isPlaybackIntended)
    let row = WideCompactCard(
      episode: episode,
      provider: homeWashProvider,
      coverClient: coverClient,
      downloadStatus: downloadStatus,
      playback: playback,
      isPlaying: isPlaying,
      isSelecting: isSelecting,
      onSelect: {
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

    let menuRow = Group {
      if !isSelecting, ItemContextMenuAvailability.offersMenu(for: .podcast) {
        row.itemContextMenu(
          ItemMenuSubject(
            episode: episode, coverClient: coverClient, playback: playback, actions: actions),
          placement: .savedForLaterRow,
          onOpen: { onSelectItem(episode.showSummary) },
          onSearch: onSearch)
      } else {
        row
      }
    }
    return savedSwipe(
      menuRow, for: entry, capability: .podcast, isSelecting: isSelecting,
      carriesMenuTwin: !ItemContextMenuAvailability.offersMenu(for: .podcast))
  }

  private func unavailableRow(_ entry: SavedShelfItem, isSelecting: Bool) -> some View {
    let itemID = entry.identity.itemID
    let coverTitle = entry.contextTitle ?? entry.subjectTitle
    let coverAuthor = entry.episode?.showAuthor ?? entry.itemSummary?.author
    let subtitle = entry.episode == nil ? nil : entry.contextTitle
    let unavailableMetadata =
      entry.episode == nil ? HomeCopy.savedItemUnavailable : PodcastCopy.unavailableOnServer
    let row = WideCompactCard(
      item: entry.washSubject,
      provider: homeWashProvider,
      coverClient: coverClient,
      title: entry.subjectTitle,
      subtitle: subtitle,
      metadata: unavailableMetadata,
      accessibilityLabel: [entry.subjectTitle, subtitle, unavailableMetadata]
        .compactMap { $0 }.joined(separator: ", "),
      coverTitle: coverTitle,
      coverAuthor: coverAuthor,
      inlineContent: {
        EmptyView()
      },
      trailingContent: {
        EmptyView()
      }
    ) { summaryRow in
      summaryRow
    }
    .accessibilityIdentifier(HomeAccessibilityID.moreItemRowPrefix + itemID)

    return savedSwipe(
      row, for: entry, capability: nil, isSelecting: isSelecting, carriesMenuTwin: true)
  }

  /// Both swipe edges for one saved row. Which capsules each row answers is `ItemSwipeActions`'
  /// decision; this view only renders and runs them.
  ///
  /// The trailing edge is tap-to-confirm: Remove from Saved is the only action every row shape
  /// supports, and a full swipe would fire it unseen. Every capsule is also on the rotor and in
  /// available rows' long-press menu. `capability` is `nil` for the unavailable placeholder.
  ///
  /// `carriesMenuTwin` is false where the row has the shared item menu (a second would compete
  /// for the press); it depends only on row shape, never `isSelecting`, so selection keeps the
  /// view type. A selecting row offers no capsules; the arrays are emptied, not the modifiers
  /// dropped, for the same reason.
  private func savedSwipe<Content: View>(
    _ content: Content, for entry: SavedShelfItem, capability: ItemMediaCapability?,
    isSelecting: Bool, carriesMenuTwin: Bool
  ) -> some View {
    let identity = entry.identity
    let listeningIdentity = ListeningQueueActionPolicy.identity(
      itemID: identity.itemID, episodeID: identity.episodeID, category: entry.category)
    let nowPlaying = playback.nowPlayingIdentity
    let swipe = ItemSwipeActions.actions(
      shelf: .savedForLater,
      capability: capability,
      deviceAction: actions.downloadAction(
        for: identity.itemID, episodeID: identity.episodeID),
      identity: listeningIdentity,
      nowPlaying: nowPlaying,
      isPlaybackIntended: playback.swipeIsPlaybackIntended(
        identity: listeningIdentity, nowPlaying: nowPlaying))
    let leadingButtons = isSelecting ? [] : ItemSwipePresentation.buttons(for: swipe.leading)
    let trailingButtons =
      isSelecting ? [] : ItemSwipePresentation.buttons(for: swipe.trailing)
    let contextButtons =
      isSelecting
      ? []
      : Self.uniqueButtons(
        ItemSwipePresentation.buttons(for: swipe.leading + swipe.trailing))

    let swiped =
      content
      .swipeActions(edge: .leading, allowsFullSwipe: true) {
        podcastEpisodeSwipeButtons(leadingButtons) { button in
          perform(button, for: entry, capability: capability)
        }
      }
      .swipeActions(edge: .trailing, allowsFullSwipe: false) {
        podcastEpisodeSwipeButtons(trailingButtons) { button in
          perform(button, for: entry, capability: capability)
        }
      }
    return Group {
      if carriesMenuTwin {
        swiped.contextMenu {
          ForEach(contextButtons) { button in
            Button(role: button.role == .destructive ? .destructive : nil) {
              perform(button, for: entry, capability: capability)
            } label: {
              Label(button.label, systemImage: button.systemImage)
            }
            .accessibilityLabel(button.accessibilityLabel)
            .accessibilityHint(button.hint)
          }
        }
      } else {
        swiped
      }
    }
  }

  /// The menu is the union of both edges, and a shelf policy is free to put the same button on
  /// each, so the union is collapsed by identity or the menu lists an action twice.
  static func uniqueButtons(
    _ buttons: [PodcastEpisodeSwipeButton]
  ) -> [PodcastEpisodeSwipeButton] {
    var seen = Set<String>()
    return buttons.filter { seen.insert($0.id).inserted }
  }

  private func perform(
    _ button: PodcastEpisodeSwipeButton, for entry: SavedShelfItem,
    capability: ItemMediaCapability?
  ) {
    guard let action = ItemSwipeAction(rawValue: button.id) else { return }
    let identity = entry.identity

    Task {
      switch action {
      case .play, .pause:
        await playback.performSwipePlayback(
          pause: action == .pause, itemID: identity.itemID, episodeID: identity.episodeID)
      case .playNext:
        await actions.playNext(itemID: identity.itemID, episodeID: identity.episodeID)
      case .read:
        onPresentReader(identity.itemID, readerTitle(for: entry), entry.category)
      case .removeFromSaved:
        await actions.removeFromSaved(itemID: identity.itemID, episodeID: identity.episodeID)
      case .download:
        await actions.requestDownload(
          itemID: identity.itemID, episodeID: identity.episodeID,
          format: capability.map(ItemSwipeActions.downloadFormat(for:)) ?? .audio)
      case .removeDownload:
        await actions.removeDownload(itemID: identity.itemID, episodeID: identity.episodeID)
      case .markAsFinished, .resetProgress:
        // The shelf's policy never emits progress actions; long press carries both.
        return
      }
    }
  }

  /// The shelf denormalises the subject title, so a Read swipe does not need the item summary.
  /// Falls back to the summary when the stored title is empty.
  private func readerTitle(for entry: SavedShelfItem) -> String {
    entry.subjectTitle.isEmpty ? (entry.itemSummary?.title ?? "") : entry.subjectTitle
  }
}
