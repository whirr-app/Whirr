import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The loaded content of a podcast show page. The screen owns lifecycle and presentation state;
/// this view owns only the section's rows and sends alert-producing actions back to that screen.
struct PodcastShowContentView: View {
  @Environment(\.editMode) private var editMode
  @Environment(\.episodeTranscriptOpener) private var transcriptOpener
  @Environment(\.watchCopies) private var watchCopies
  /// Held here because expanding inserts a row: the header shows only the synopsis's first three
  /// lines, and the rest is its own row below it.
  @State private var isSynopsisExpanded = false

  let model: PodcastShowModel
  let item: ItemSummary
  let palette: PodcastShowViewPresentation.ShowPalette
  let itemID: String
  let availableWidth: CGFloat
  let horizontalSizeClass: UserInterfaceSizeClass?
  let coverClient: any ArtworkServing
  let playback: PlaybackModel
  let artworkDisplaySize: CGFloat
  let coverSize: CGFloat
  let onSearch: (String) -> Void
  let onPresentEpisode: (NavigationModel.PodcastEpisodeRef) -> Void
  let onOpenShowSettings: (String?) -> Void
  let onRequestUnsubscribe: () -> Void
  let onDownloadFailure: (ItemDownloadStatus, String, Bool) -> Void
  let onRequestServerRemoval: (String) -> Void
  /// Whether the header's own title is on screen; the screen names the show in its bar otherwise.
  let onHeaderTitleVisibilityChange: (Bool) -> Void

  /// The header card's bottom padding, kept below the synopsis continuation when there is one.
  private var headerBottomSpacer: some View {
    Color.clear
      .frame(height: WhirrSpacing.small)
      .accessibilityHidden(true)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .selectionDisabled()
  }

  private var episodeRowHorizontalInset: CGFloat {
    PodcastsViewPresentation.boundedRowHorizontalInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  /// Search and chips already carry the compact editorial margin internally. Only the regular
  /// width's additional inset belongs outside those controls so their visible edges match a row.
  private var additionalHorizontalInset: CGFloat {
    max(0, episodeRowHorizontalInset - WhirrSpacing.medium)
  }

  var body: some View {
    let filteredEpisodes = model.filteredEpisodes
    let placeholder = PodcastShowViewPresentation.placeholder(
      state: model.state,
      hasReadEpisodeCache: model.hasReadEpisodeCache,
      episodeCount: model.episodes.count,
      filteredEpisodeCount: filteredEpisodes.count,
      filter: model.filter,
      query: model.episodeQuery)

    let synopsis = PodcastShowPresentation.synopsis(from: item.itemDescription)

    return Section {
      PodcastShowHeaderView(
        title: item.title,
        subtitle: item.author,
        synopsis: synopsis,
        isSynopsisExpanded: $isSynopsisExpanded,
        sourceCaption: PodcastShowSourcePresentation.showCaption(itemID: itemID),
        sourceCaptionSymbolName: PodcastShowViewPresentation.sourceCaptionSymbolName(for: itemID),
        badgeLabel: HomeRowPresentation.badgeLabel(for: .podcast),
        onTitleVisibilityChange: onHeaderTitleVisibilityChange
      ) {
        CoverImageView(
          itemID: itemID, title: item.title, displaySize: artworkDisplaySize,
          client: coverClient, source: item.providerArtworkSource, role: .homeCard,
          artworkGlow: PodcastShowViewPresentation.headerCoverGlows,
          revision: item.artworkRevision
        )
        .frame(width: coverSize, height: coverSize)
      }
      .accessibilityIdentifier(PodcastAccessibilityID.showHeader)
      // No bottom padding: the synopsis continuation, when shown, runs on from the header's last
      // line. `headerBottomSpacer` supplies the gap after both.
      .padding([.top, .horizontal], WhirrSpacing.small)
      .editorialCardSurface(palette.headerFill)
      // The header sits on the page's wash, not a card of its own, so it declares that for
      // `WashInk` and for the cover's glow, which takes its colour from it.
      .drawnOnCoverWash(palette.headerWash)
      .listRowInsets(
        EdgeInsets(
          top: WhirrSpacing.small, leading: episodeRowHorizontalInset, bottom: 0,
          trailing: episodeRowHorizontalInset)
      )
      .listRowSeparator(.hidden)
      // Not `editorialCardListRow`: the insets are asymmetric (tight against the filter chips
      // below), and with no swipe actions there is no container to mask the fill. The wash is the
      // page's, not this row's: a cell cannot reach behind the navigation bar, so a wash that
      // stopped at the header's top edge would leave the bar strip plain.
      .listRowBackground(Color.clear)
      .selectionDisabled()

      // A row of its own, not a taller header: a `List` animates a row's insertion, with the
      // rows below sliding, but snaps a row that changes height in place.
      if isSynopsisExpanded, let synopsis {
        PodcastShowSynopsisContinuationView(synopsis: synopsis)
          .padding(.horizontal, WhirrSpacing.small)
          .contentShape(Rectangle())
          .onTapGesture {
            withAnimation(PodcastShowHeaderView<EmptyView>.synopsisAnimation) {
              isSynopsisExpanded = false
            }
          }
          .drawnOnCoverWash(palette.headerWash)
          .listRowInsets(
            EdgeInsets(
              top: 0, leading: episodeRowHorizontalInset, bottom: 0,
              trailing: episodeRowHorizontalInset)
          )
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .selectionDisabled()
      }

      headerBottomSpacer

      if model.needsAttention {
        VStack(alignment: .leading, spacing: WhirrSpacing.small) {
          Text(PodcastShowRecoveryPresentation.title)
            .font(WhirrTypeToken.headline.font)
          HStack {
            Button(PodcastShowRecoveryPresentation.retryPasswordLabel) {
              onOpenShowSettings(item.title)
            }
            Button(PodcastShowRecoveryPresentation.removeFeedLabel, role: .destructive) {
              onRequestUnsubscribe()
            }
          }
        }
        .padding(.horizontal, episodeRowHorizontalInset)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled()
      }

      PodcastEpisodeSearchField(
        query: Binding(
          get: { model.episodeQuery },
          set: { model.episodeQuery = $0 }),
        tint: palette.accent,
        onFocus: { model.warmEpisodeSearchKeys() }
      )
      .padding(.horizontal, additionalHorizontalInset)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
      .selectionDisabled()

      filterPicker(accent: palette.accent)
        .padding(.horizontal, additionalHorizontalInset)
        // The chips row carries its own leading inset and scrolls horizontally; the list row's
        // default insets would double the margin and clip the scroll.
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .selectionDisabled()

      switch placeholder {
      case .loading(let message):
        LoadingStateView(message: message)
          // A list row hugs its content to the leading edge; centre the placeholder under the
          // chips like the empty state.
          .frame(maxWidth: .infinity)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .selectionDisabled()
      case .empty(let title, let message, let systemImage):
        EmptyStateView(title: title, message: message, systemImage: systemImage)
          .listRowSeparator(.hidden)
          // A placeholder cell is tall, so its default `systemBackground` fill would cut the wash
          // off at a hard edge across the screen when a filter matches nothing.
          // `scrollContentBackground(.hidden)` hides the scroll view's background, not the cell's.
          .listRowBackground(Color.clear)
          .selectionDisabled()
      case nil:
        // One read of the player's identity for the whole list. Resolving it per row would make
        // every recycled row a dependent of the player; the per-row part of the decision is pure
        // (`ListeningQueueActionPolicy`).
        let nowPlaying = playback.nowPlayingIdentity
        ForEach(filteredEpisodes) { episode in
          episodeRow(episode, creator: item.author, nowPlaying: nowPlaying, palette: palette)
            .tag(episode.id)
            // With no card of its own, a row is told from its neighbour by a hairline. The cell's
            // fill is `editorialCardListRow`'s to declare; a second `listRowBackground` out here
            // would be silently discarded.
            .listRowSeparator(palette.separatesEpisodeRows ? .visible : .hidden)
            // The system hairline stops at the list's trailing edge, not the row's, so at regular
            // width it overhangs the bounded row by the extra inset. Binding the guide to the
            // row's own box is a no-op at compact width, where the edges coincide.
            .alignmentGuide(.listRowSeparatorTrailing) { $0[.trailing] }
        }
      }

      if let actionErrorMessage = model.actionErrorMessage {
        Text(actionErrorMessage)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(.red)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .selectionDisabled()
      }
      if model.serverSave.serverSaveStatus != .none,
        let serverSaveStatusText = model.serverSave.serverSaveFeedbackMessage
      {
        Text(serverSaveStatusText)
          .font(WhirrTypeToken.caption.font)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(
            NativeEpisodeServerSaveCopy.accessibilityLabel(for: model.serverSave.serverSaveStatus)
          )
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .selectionDisabled()
      }
      if let progress = model.serverSave.batchServerSave?.progressText {
        Text(progress)
          .font(WhirrTypeToken.caption.font)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel(model.serverSave.batchServerSave?.progressAccessibilityLabel ?? progress)
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .selectionDisabled()
      }
    }
  }

  private func filterPicker(accent: Color?) -> some View {
    let filters = PodcastEpisodeFilter.allCases
    return MediaFilterPicker(
      title: "Episode Filter",
      labels: filters.map(PodcastShowListCopy.filterLabel),
      selectedIndex: filters.firstIndex(of: model.filter) ?? 0,
      style: .chips,
      selectionTint: accent,
      onSelect: { index in
        guard filters.indices.contains(index) else { return }
        model.filter = filters[index]
      }
    )
    .accessibilityIdentifier(PodcastAccessibilityID.showFilter)
  }

  private func episodeRow(
    _ episode: PodcastEpisodeSummary,
    creator: String?,
    nowPlaying: ListeningIdentity?,
    palette: PodcastShowViewPresentation.ShowPalette
  ) -> some View {
    // Same resolution as the menu's `queueAvailability`. Constructing the identity directly
    // accepts only the ABS namespace, so a native feed's `rss:` item id would be `nil` and drop
    // the row's leading swipe while the menu's Play Next stayed.
    let identity = ListeningQueueActionPolicy.identity(
      itemID: itemID, episodeID: episode.id, category: .podcast)
    // Server-save state is not read here. The row reads it in its own `body`, so a status write
    // during a batch save invalidates the visible rows, not this section, its `List` diff, or the
    // toolbar that shares the model.
    let inputs = PodcastShowEpisodeRow.Inputs(
      creator: creator,
      isSaved: model.isSaved(episodeID: episode.id),
      queueAvailability: ListeningQueueActionPolicy.availability(
        itemID: itemID, episodeID: episode.id, category: .podcast, nowPlaying: nowPlaying),
      isCurrentlyPlaying: playback.isPlaybackIntended(
        for: itemID, episodeID: episode.id),
      isHidden: model.isHiddenFromContinueListening(episodeID: episode.id),
      isCheckingForAds: AdSkipActivityModel.shared.isAnalysing(itemID: itemID, episodeID: episode.id))
    let policy = PodcastEpisodeSwipeActions.actions(
      deviceAction: ItemContextMenuDownloadAction.resolve(episode.downloadStatus),
      isAvailableOnServer: episode.isAvailableOnServer,
      playbackStatus: MediaProgressActionPolicy.playbackStatus(
        progressSeconds: episode.progressSeconds, isFinished: episode.isFinished),
      identity: identity,
      nowPlaying: nowPlaying,
      isPlaybackIntended: inputs.isCurrentlyPlaying)
    let swipeActions = PodcastShowViewPresentation.swipeButtons(for: policy)
    return PodcastShowEpisodeRow(
      model: model,
      playback: playback,
      itemID: itemID,
      episode: episode,
      inputs: inputs,
      accent: palette.pageMark,
      onSelect: {
        onPresentEpisode(
          PodcastShowViewPresentation.episodeRowSelection(itemID: itemID, episodeID: episode.id))
      },
      onSelectAction: { action in
        if action.id == PodcastEpisodeViewAction.explainDownloadFailure.rawValue {
          // Explain first; the retry is dispatched only from the alert's Try Again.
          onDownloadFailure(
            episode.downloadStatus, episode.id, episode.isAvailableOnServer)
          return
        }
        if action.id == PodcastEpisodeViewAction.moreFromCreator.rawValue {
          if let creator { onSearch(creator) }
          return
        }
        if action.id == PodcastEpisodeViewAction.saveToServer.rawValue {
          Task { await model.serverSave.saveEpisodeToServer(episodeID: episode.id) }
          return
        }
        if action.id == PodcastEpisodeViewAction.removeFromServer.rawValue {
          onRequestServerRemoval(episode.id)
          return
        }
        if action.id == PodcastEpisodeViewAction.transcript.rawValue {
          transcriptOpener?.open(itemID, episode.id, palette.accent)
          return
        }
        Task { await perform(actionID: action.id, episodeID: episode.id) }
      }
    )
    // An unfilled row loses the card's inner padding, so it takes the room back as row inset.
    // Otherwise the hairlines close in on the text.
    .editorialCardListRow(
      palette.episodeRowFill,
      horizontalInset: episodeRowHorizontalInset,
      verticalInset: WhirrSpacing.small
    )
    .accessibilityIdentifier(
      PodcastAccessibilityID.episodeRow(showID: itemID, episodeID: episode.id)
    )
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      podcastEpisodeSwipeButtons(editMode?.wrappedValue.isEditing == true ? [] : swipeActions?.leading ?? []) {
        button in
        Task { await performSwipe(button, episodeID: episode.id) }
      }
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      podcastEpisodeSwipeButtons(editMode?.wrappedValue.isEditing == true ? [] : swipeActions?.trailing ?? []) {
        button in
        Task { await perform(actionID: button.id, episodeID: episode.id) }
      }
    }
  }

  /// The model's `.playPause` always starts a fresh session, which is right for the menu's Play
  /// Episode but not for the loaded row's capsule: that one pauses, or resumes in place.
  private func performSwipe(_ button: PodcastEpisodeSwipeButton, episodeID: String) async {
    guard button.id == PodcastEpisodeViewAction.playPause.rawValue,
      playback.isLoaded(itemID: itemID, episodeID: episodeID)
    else {
      await perform(actionID: button.id, episodeID: episodeID)
      return
    }
    await playback.performSwipePlayback(
      pause: button == PodcastShowViewPresentation.pauseSwipeButton, itemID: itemID,
      episodeID: episodeID)
  }

  private func perform(actionID: String, episodeID: String) async {
    guard let episodeAction = MediaItemAction(actionID: actionID),
      episodeAction != .openShow,
      episodeAction != .moreFromCreator
    else { return }
    if episodeAction == .saveToServer {
      await model.serverSave.saveEpisodeToServer(episodeID: episodeID)
      return
    }
    if episodeAction == .removeFromServer {
      onRequestServerRemoval(episodeID)
      return
    }
    if episodeAction == .sendToWatch {
      await watchCopies?.send(itemID: itemID, episodeID: episodeID)
      return
    }
    if episodeAction == .removeFromWatch {
      await watchCopies?.remove(itemID: itemID, episodeID: episodeID)
      return
    }
    await model.performAction(episodeAction, episodeID: episodeID)
  }
}

/// One episode row with its own `body`, so state that moves while the list doesn't is read here:
/// download fraction (every 2%), server-save state (every attempt-table write of a batch save)
/// and printed progress invalidate only visible rows, and the playing row follows the playhead
/// without invalidating the list. The content view resolves list-pass state (saved membership,
/// queue availability, player identity) and passes it as `Inputs`.
private struct PodcastShowEpisodeRow: View {
  @Environment(\.episodeTranscriptOpener) private var transcriptOpener
  @Environment(\.watchCopies) private var watchCopies

  struct Inputs: Equatable {
    let creator: String?
    let isSaved: Bool?
    let queueAvailability: ListeningQueueActionAvailability
    let isCurrentlyPlaying: Bool
    let isHidden: Bool
    let isCheckingForAds: Bool
  }

  let model: PodcastShowModel
  let playback: PlaybackModel
  let itemID: String
  let episode: PodcastEpisodeSummary
  let inputs: Inputs
  let accent: Color?
  let onSelect: () -> Void
  let onSelectAction: (MediaContextAction) -> Void

  var body: some View {
    let row = presentation
    return PodcastEpisodeRowView(
      title: row.title,
      synopsis: row.synopsis,
      dateText: row.dateText,
      durationText: row.durationText,
      progressText: row.progressText,
      playbackProgressFraction: row.playbackProgressFraction,
      playbackStatus: row.playbackStatus,
      playbackStatusText: row.playbackStatusText,
      serverAvailability: row.serverAvailability,
      serverAvailabilityText: row.serverAvailabilityText,
      deviceStatus: liveDeviceStatus(row),
      downloadAction: row.downloadAction,
      watchMark: PodcastShowViewPresentation.watchMark(
        for: watchCopies?.watchCopyState(itemID: itemID, episodeID: episode.id)),
      accent: accent,
      isCheckingForAds: inputs.isCheckingForAds,
      selectionAccessibilityHint: "Opens the episode.",
      contextMenuAccessibilityLabel: "Episode actions",
      contextMenuAccessibilityHint:
        "Shows playback, saved, navigation, download, and progress actions.",
      contextActionSections: row.actionSections,
      onSelect: onSelect,
      onSelectAction: onSelectAction)
  }

  /// The row's presentation, built here because the server-save availability it folds into the
  /// action sections is the part of a row that changes during a batch save.
  private var presentation: PodcastShowViewPresentation.Episode {
    let serverSave: NativeEpisodeServerSaveAvailability
    let serverRemove: NativeEpisodeServerSaveAvailability
    if model.serverSave.isBatchServerSaveMember(episode.id) {
      // The batch owns these rows until its outcome lands; row actions must not race it.
      serverSave = .disabled(.unavailable)
      serverRemove = .hidden
    } else {
      let status = model.serverSave.serverSaveStatus(for: episode.id)
      serverSave = NativeEpisodeServerSaveStatus.saveAvailability(
        capability: model.serverSave.serverMutationCapability,
        isNativeFeed: model.isNativeFeed,
        isCredentialedFeed: model.serverSave.isCredentialedNativeFeed,
        status: status)
      serverRemove = NativeEpisodeServerSaveStatus.removeAvailability(
        capability: model.serverSave.serverMutationCapability,
        isNativeFeed: model.serverSave.hostsServerSaveRemoval,
        status: status,
        preflightPresence: model.serverSave.serverSavePreflightPresence(for: episode.id))
    }
    return PodcastShowViewPresentation.episode(
      episode,
      progressSeconds: playback.listPositionSeconds(
        itemID: itemID, episodeID: episode.id, persisted: episode.progressSeconds),
      creator: inputs.creator,
      isSaved: inputs.isSaved,
      queueAvailability: inputs.queueAvailability,
      isCurrentlyPlaying: inputs.isCurrentlyPlaying,
      isHidden: inputs.isHidden,
      serverSave: serverSave,
      serverRemove: serverRemove,
      offersTranscript: transcriptOpener != nil,
      watchCopy: watchCopies?.watchCopy(itemID: itemID, episodeID: episode.id))
  }

  /// The list reports a downloading row as fraction `0`; the ring's fraction is resolved here
  /// from the progress projection. Only a `.downloading` row with a known total asks the model,
  /// so other rows register no dependency on the progress map.
  private func liveDeviceStatus(
    _ row: PodcastShowViewPresentation.Episode
  ) -> PodcastEpisodeDeviceDownloadStatus {
    guard case .downloading = episode.downloadStatus, episode.isDownloadSizeKnown,
      let fraction = model.downloadProgressFraction(for: episode.id)
    else { return row.deviceStatus }
    return PodcastShowViewPresentation.deviceStatus(
      for: .downloading(progressFraction: fraction),
      isDownloadSizeKnown: episode.isDownloadSizeKnown)
  }
}
