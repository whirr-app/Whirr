import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// `DownloadsView`'s list: the rows themselves, the placeholder over them, and the membership
/// mirror that gives a confirmed deletion its motion. Selection lives in `DownloadsView+Selection`
/// and the destructive storage controls in `DownloadsView+Storage`.
extension DownloadsView {
  var content: some View {
    return
      downloadsList
      // An overlay, not a row: the placeholder must never become scroll content.
      .overlay {
        if let placeholder = statePlaceholder {
          placeholderView(placeholder)
            .allowsHitTesting(placeholder.allowsHitTesting)
        }
      }
  }
  var statePlaceholder: DownloadsViewPresentation.Placeholder? {
    // The eviction summary does not suppress a placeholder. It is durable, so it would defeat the
    // loading state on any device that has hit the ceiling, and leave the empty state as a lone
    // "Delete all" over no rows. A pass only deletes down to the cap, so the disclosure below is
    // reachable whenever downloads remain.
    DownloadsViewPresentation.placeholder(
      homeState: homeModel.state,
      hasLoadedDownloadedItems: storageModel.hasLoadedDownloadedItems,
      hasRows: visibleDownloadRows.isEmpty == false)
  }

  @ViewBuilder
  func placeholderView(
    _ placeholder: DownloadsViewPresentation.Placeholder
  ) -> some View {
    switch placeholder {
    case .loading:
      LoadingStateView(message: "Loading downloads…")
    case .empty:
      EmptyStateView(
        title: HomeCopy.downloadedTitle,
        message: HomeCopy.downloadedEmpty,
        systemImage: "arrow.down.circle")
    }
  }
  /// One list in both states. Selecting adds the checkmarks and takes each row's own controls
  /// away. The screen-level rows (banner, totals, eviction summary) stay and opt out of selection;
  /// only the two destructive footers leave, since batch removal is what selection is for.
  var downloadsList: some View {
    let isSelecting = selectionEditMode.isEditing
    return List(selection: isSelecting ? $selectedDownloadIDs : nil) {
      // Only with the Watch app installed, and out of the way while rows are being selected.
      if !isSelecting, watchCopies?.isWatchAppInstalled == true {
        NavigationLink {
          OnAppleWatchView(coverClient: coverClient)
        } label: {
          Label(OnAppleWatchPresentation.title, systemImage: "applewatch")
        }
        .selectionDisabled()
        .accessibilityIdentifier("downloads.onAppleWatch")
      }

      if statePlaceholder == nil {
        if storageModel.isQueuePausedForLowDisk {
          lowDiskBanner
            .selectionDisabled()
        }

        Text(HomeCopy.downloadedStorageAmount(bytes: storageModel.downloadedItemsTotalBytes))
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .monospacedDigit()
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
          .listRowInsets(
            EdgeInsets(
              top: WhirrSpacing.xxSmall, leading: WhirrSpacing.medium,
              bottom: WhirrSpacing.xSmall, trailing: WhirrSpacing.medium)
          )
          .selectionDisabled()
          .accessibilityIdentifier(ScreenAccessibilityID.storageTotals)

        if let summary = storageModel.lastStorageCeilingSummary {
          Text(StorageCopy.storageCeilingEvictionSummary(summary))
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .selectionDisabled()
            .accessibilityIdentifier(ScreenAccessibilityID.storageCeilingSummary)
        }

        ForEach(downloadedHomeItems) { item in
          downloadRow(item)
        }

        if nativeSubscriptionsEnabled {
          RSSDownloadsView(
            model: rssDownloadsModel,
            feeds: rssFeeds,
            homeWashProvider: homeWashProvider,
            coverClient: coverClient,
            onRequestDelete: { pendingDeletion = $0 },
            isSelecting: isSelecting
          )
        }

        if !isSelecting {
          if storageModel.hasTombstonedEpisodeBytes {
            reclaimRemovedEpisodesButton
              .listRowSeparator(.hidden)
              .listRowBackground(Color.clear)
              .listRowInsets(
                EdgeInsets(
                  top: WhirrSpacing.medium, leading: WhirrSpacing.medium,
                  bottom: 0, trailing: WhirrSpacing.medium))
          }

          deleteAllButton
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(
              EdgeInsets(
                top: WhirrSpacing.medium, leading: WhirrSpacing.medium,
                bottom: WhirrSpacing.large, trailing: WhirrSpacing.medium))
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .primaryScrollEdgeEffect(role: selectionEditMode.isEditing ? .selecting : .titled)
    .selectionMarkTint(isSelecting: isSelecting)
    .onChange(of: DownloadsViewPresentation.absItemIDs(from: storageModel.rows), initial: true) {
      _, itemIDs in
      mirrorRowMembership(wasEmpty: downloadedItemIDs.isEmpty) {
        downloadedItemIDs = Set(itemIDs)
      }
    }
    .onChange(of: observedRSSFeeds, initial: true) { _, feeds in
      mirrorRowMembership(wasEmpty: rssFeeds.isEmpty) {
        rssFeeds = feeds
      }
    }
    .accessibilityIdentifier(ScreenAccessibilityID.storageList)
  }

  func mirrorRowMembership(wasEmpty: Bool, _ write: () -> Void) {
    guard DownloadsViewPresentation.animatesRowMembershipChange(wasEmpty: wasEmpty) else {
      write()
      return
    }
    withAnimation(DownloadsViewPresentation.rowRemovalMotion(reduceMotion: reduceMotion), write)
  }

  /// Dormant while native subscriptions are off: the model, and the observation it opens, is not
  /// resolved at all.
  var observedRSSFeeds: [RSSDownloadedFeed] {
    nativeSubscriptionsEnabled ? rssDownloadsModel.feeds : []
  }

  @ViewBuilder
  func downloadRow(_ item: HomeItem) -> some View {
    let presentation = HomeMoreItemRowPresentation(item: item, section: .downloaded)
    let storageRow = storageModel.rows.first { $0.itemId == item.serverItemId }
    let mediaTypeText = presentation.metadataText
    let sizeText = storageRow.map {
      StorageCopy.itemSizeDetail(
        totalBytes: $0.totalBytes, removedEpisodeBytes: $0.tombstonedEpisodeBytes)
    }
    let isPodcast = item.category == .podcast
    let isExpanded = expandedPodcastIDs.contains(item.serverItemId)
    let isDeleting = storageRow?.isDeleting == true
    let isSelecting = selectionEditMode.isEditing

    let rowText = HomeMoreEditorialRowPresentation.text(from: presentation)

    WideCompactCard(
      item: item.washSubject,
      provider: homeWashProvider,
      coverClient: coverClient,
      title: presentation.title,
      subtitle: rowText.subtitle,
      metadata: [mediaTypeText, sizeText].compactMap { $0 }.joined(separator: " · "),
      accessibilityLabel: [presentation.accessibilityLabel, sizeText]
        .compactMap { $0 }
        .joined(separator: ", "),
      eyebrow: rowText.eyebrow,
      coverTitle: item.title,
      coverAuthor: item.author,
      inlineContent: { EmptyView() },
      trailingContent: { EmptyView() },
      bookZoomSource: bookZoomTransition?.source(
        item: item.itemSummary,
        occurrence: "downloads-\(bookZoomOccurrenceID.uuidString)/\(item.serverItemId)")
    ) { summaryRow in
      if isSelecting {
        // While selecting, the disclosure goes the way the open button and swipes do: the folder
        // is ticked as a whole. The list cell owns the tap, so a nested disclosure would not
        // receive one anyway.
        summaryRow.contentShape(Rectangle())
      } else if isPodcast {
        DisclosureGroup(
          isExpanded: Binding(
            get: { expandedPodcastIDs.contains(item.serverItemId) },
            set: { expanded in
              if expanded {
                expandedPodcastIDs.insert(item.serverItemId)
              } else {
                expandedPodcastIDs.remove(item.serverItemId)
              }
            }
          )
        ) {
          DownloadedPodcastEpisodesView(
            itemID: item.serverItemId,
            model: podcastShowModel(item.serverItemId),
            onRequestDelete: { pendingDeletion = $0 }
          )
          .padding(.leading, DownloadsViewPresentation.episodeContentLeadingInset)
        } label: {
          summaryRow
            // Keep the show's action on the disclosure label rather than its container. SwiftUI
            // applies container swipe actions to every disclosed child row, which otherwise gives
            // an episode both the show's Delete action and its own episode Delete action.
            .downloadDeleteSwipeAction(
              label: "Remove downloads for \(item.title)",
              hint: "Asks for confirmation before removing.",
              isDeleting: isDeleting,
              carriesMenuTwin: false
            ) {
              storageModel.requestPurge(itemId: item.serverItemId, title: item.title)
            }
            .modifier(downloadRowMenu(item, isDeleting: isDeleting))
        }
        .accessibilityHint(
          isExpanded ? "Collapses downloaded episodes." : "Expands downloaded episodes."
        )
        .onAppear {
          // Opens the show's episode observation now, so the folder has its episodes (and a real
          // height) when a first expansion animates.
          podcastShowModel(item.serverItemId)
        }
      } else {
        Button {
          if bookZoomTransition?.selectBook(
            item.itemSummary,
            occurrence: "downloads-\(bookZoomOccurrenceID.uuidString)/\(item.serverItemId)",
            artworkRole: .libraryThumbnail, displaySize: Self.coverSize) != true
          {
            onSelectItem(item.itemSummary)
          }
        } label: {
          summaryRow
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this title.")
        .downloadDeleteSwipeAction(
          label: "Remove downloads for \(item.title)",
          hint: "Asks for confirmation before removing.",
          isDeleting: isDeleting,
          carriesMenuTwin: false
        ) {
          storageModel.requestPurge(itemId: item.serverItemId, title: item.title)
        }
        .modifier(downloadRowMenu(item, isDeleting: isDeleting))
      }
    }
    .accessibilityIdentifier(ScreenAccessibilityID.storageRowPrefix + item.serverItemId)
    // Tagged in both states; the tag is inert while `List(selection:)` is nil.
    .tag(DownloadsViewPresentation.SelectionID.absItem(item.serverItemId))
    .selectionDisabled(!eligibleSelectionIDs.contains(.absItem(item.serverItemId)))
  }

  /// The shared item menu, closing with this screen's confirmed Delete (the swipe's menu twin) in
  /// place of the menu's own unconfirmed download entry.
  func downloadRowMenu(_ item: HomeItem, isDeleting: Bool) -> DownloadRowMenuModifier {
    DownloadRowMenuModifier(
      item: item, coverClient: coverClient, playback: playback, actions: actions,
      closingAction: ItemMenuClosingAction(
        title: MediaActionCopy.removeDownload.title,
        systemImage: MediaActionCopy.removeDownload.systemImage,
        isDisabled: isDeleting,
        action: { storageModel.requestPurge(itemId: item.serverItemId, title: item.title) }),
      onOpen: { onSelectItem(item.itemSummary) },
      onPresentReader: onPresentReader,
      onSearch: onSearch)
  }

  @discardableResult
  func podcastShowModel(_ itemID: String) -> PodcastShowModel {
    podcastShowModels.resolve(itemID) { makePodcastShowModel(itemID, .downloaded) }
  }

  /// Storage is the authority for membership. Waiting for its first snapshot, then intersecting it
  /// with Home's artwork-rich metadata, guarantees every row has the size from that same snapshot.
  /// Membership is read from the animated mirror, which trails the model by one update, so a row
  /// whose storage entry has gone shows no size for the frame it takes to leave.
  var downloadedHomeItems: [HomeItem] {
    homeModel.items.filter { downloadedItemIDs.contains($0.serverItemId) }
  }

  var visibleDownloadRows: [DownloadsViewPresentation.Row] {
    DownloadsViewPresentation.mergedRows(
      absItemIDs: DownloadsViewPresentation.absItemIDs(from: storageModel.rows),
      rssFeedIDs: nativeSubscriptionsEnabled ? rssDownloadsModel.feeds.map(\.id) : [],
      nativeSubscriptionsEnabled: nativeSubscriptionsEnabled)
  }
}

struct DownloadRowMenuModifier: ViewModifier {
  let item: HomeItem
  let coverClient: any ArtworkServing
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let closingAction: ItemMenuClosingAction
  let onOpen: () -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void

  func body(content: Content) -> some View {
    content.itemContextMenu(
      ItemMenuSubject(
        item: item, coverClient: coverClient, playback: playback, actions: actions),
      placement: .downloadsRow,
      bookSurface: .downloads,
      closingAction: closingAction,
      onOpen: onOpen,
      onRead: { onPresentReader(item.serverItemId, item.title, item.category) },
      onSearch: onSearch)
  }
}
