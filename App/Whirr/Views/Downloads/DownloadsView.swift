import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import SyncEngine

/// The one download-management destination used by both Home and Settings.
///
/// Its artwork-led rows follow Home's "See All" presentation, while `StorageModel` supplies the
/// destructive item/account actions and their confirmation flow. Podcast rows expand in place so a
/// show can be removed as a whole or one downloaded episode at a time.
struct DownloadsView: View {
  static let coverSize: CGFloat = HomeMoreView.coverSize

  @State var deferredHome = DeferredModel<HomeMoreModel>()
  @State var deferredStorage = DeferredModel<StorageModel>()
  @State var deferredRSSDownloads = DeferredModel<RSSDownloadsModel>()
  /// One `PodcastShowModel` per downloaded show, warmed when the show's row appears rather than
  /// when its folder is first expanded (`DownloadsViewPresentation.episodeObservationWarmUp`).
  @State var podcastShowModels = KeyedDeferredModels<String, PodcastShowModel>()
  @State var expandedPodcastIDs: Set<String> = []
  @State var pendingDeletion: PendingDownloadDeletion?
  @State var homeWashProvider: HomeWashProvider
  /// The rows' membership, mirrored from the models under a removal transaction so a confirmed
  /// deletion leaves the list with motion (`DownloadsViewPresentation.rowRemovalMotion`). Sizes
  /// and every other per-row value are read live from the models.
  @State var downloadedItemIDs: Set<String> = []
  @State var rssFeeds: [RSSDownloadedFeed] = []
  @State var selectionEditMode: EditMode = .inactive
  @State var selectedDownloadIDs: Set<DownloadsViewPresentation.SelectionID> = []
  @State var pendingDownloadIDs: Set<DownloadsViewPresentation.SelectionID> = []
  @State var isPerformingSelectionAction = false
  @State var selectionErrorMessage: String?
  /// The zoom transition's per-appearance namespace, and the context that owns it.
  @State var bookZoomOccurrenceID = UUID()
  @Environment(\.bookZoomTransitionContext) var bookZoomTransition
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  /// Offers the On Apple Watch link only to a listener with the Watch app installed.
  @Environment(\.watchCopies) var watchCopies

  let makeHomeModel: () -> HomeMoreModel
  let makePodcastShowModel: (String, PodcastEpisodeFilter) -> PodcastShowModel
  let storageReading: any StorageReading
  let rssDownloadsReading: any RSSDownloadsReading
  let nativeSubscriptionsEnabled: Bool
  let storageCeilingSummaryReading: any StorageCeilingSummaryReading
  let downloadIntents: any DownloadIntents
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  /// The shared long-press menu's models, as on every other item list.
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelectItem: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void

  init(
    makeHomeModel: @escaping () -> HomeMoreModel,
    makePodcastShowModel: @escaping (String, PodcastEpisodeFilter) -> PodcastShowModel,
    storageReading: any StorageReading,
    rssDownloadsReading: any RSSDownloadsReading = NoOpRSSDownloadsReading(),
    nativeSubscriptionsEnabled: Bool,
    storageCeilingSummaryReading: any StorageCeilingSummaryReading =
      NoOpStorageCeilingSummaryStore(),
    downloadIntents: any DownloadIntents,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    onSelectItem: @escaping (ItemSummary) -> Void,
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void,
    onSearch: @escaping (String) -> Void
  ) {
    self.makeHomeModel = makeHomeModel
    self.makePodcastShowModel = makePodcastShowModel
    self.storageReading = storageReading
    self.rssDownloadsReading = rssDownloadsReading
    self.nativeSubscriptionsEnabled = nativeSubscriptionsEnabled
    self.storageCeilingSummaryReading = storageCeilingSummaryReading
    self.downloadIntents = downloadIntents
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.playback = playback
    self.actions = actions
    self.onSelectItem = onSelectItem
    self.onPresentReader = onPresentReader
    self.onSearch = onSearch
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: Self.coverSize, displayScale: 1, artworkRole: .libraryThumbnail))
  }

  var homeModel: HomeMoreModel {
    deferredHome.resolve(makeHomeModel)
  }

  var storageModel: StorageModel {
    deferredStorage.resolve {
      StorageModel(
        storageReading: storageReading,
        downloadIntents: downloadIntents,
        storageCeilingSummary: storageCeilingSummaryReading)
    }
  }

  var rssDownloadsModel: RSSDownloadsModel {
    deferredRSSDownloads.resolve {
      RSSDownloadsModel(reading: rssDownloadsReading, downloadIntents: downloadIntents)
    }
  }

  var body: some View {
    content
      .disabled(isPerformingSelectionAction)
      .toolbar { selectionToolbar }
      .toolbar(selectionEditMode.isEditing ? .hidden : .automatic, for: .tabBar)
      .hidesPlayerAccessory(whileSelecting: selectionEditMode.isEditing)
      .environment(\.editMode, $selectionEditMode)
      .navigationBarBackButtonHidden(selectionEditMode.isEditing)
      .onChange(of: selectionEditMode) { _, mode in
        if !mode.isEditing { selectedDownloadIDs.removeAll() }
      }
      .onChange(of: eligibleSelectionIDs) { _, ids in selectedDownloadIDs.formIntersection(ids) }
      .alert(
        "Remove Selected Downloads?",
        isPresented: Binding(
          get: { !pendingDownloadIDs.isEmpty }, set: { _ in }
        )
      ) {
        Button("Cancel", role: .cancel) { pendingDownloadIDs.removeAll() }
        Button(MediaActionCopy.removeDownloads.title, role: .destructive) { confirmSelectionDeletion() }
      } message: {
        Text("Remove \(pendingDownloadIDs.count) selected downloads from this device?")
      }
      .selectionChrome(
        isSelecting: selectionEditMode.isEditing,
        selectionTitle: SelectionChromePresentation.title(
          screen: .downloads,
          selectedCount: selectedDownloadIDs.count,
          isWorking: isPerformingSelectionAction),
        title: HomeCopy.downloadedTitle,
        titleDisplayMode: .inline
      )
      .refreshable { await homeModel.refresh() }
      .task {
        watchCopies?.refreshWatchAvailability()
        await storageModel.refreshLowDiskStatus()
      }
      .alert(
        HomeCopy.downloadedTitle,
        isPresented: Binding(
          get: { !isPerformingSelectionAction && actionErrorMessage != nil },
          set: { if !$0 && !isPerformingSelectionAction { dismissActionError() } }
        )
      ) {
        Button("OK", role: .cancel) { dismissActionError() }
      } message: {
        Text(actionErrorMessage ?? "")
      }
      // A row is torn down when its swipe action closes, so these confirmations are hosted on the
      // screen to survive that. They are alerts, not dialogs, because a dialog would anchor to the
      // screen root instead of the row (`DownloadsViewPresentation.PurgeConfirmation`).
      .downloadPurgeConfirmationAlert(
        isPresented: purgeConfirmationBinding,
        title: purgeConfirmationTitle,
        message: purgeConfirmationMessage,
        onConfirm: confirmPurge,
        onCancel: storageModel.cancelPurge
      )
      .downloadPurgeConfirmationAlert(
        isPresented: Binding(
          get: { pendingDeletion != nil },
          set: { _ in }
        ),
        title: pendingDeletion?.alertTitle ?? "",
        message: pendingDeletion?.message ?? "",
        onConfirm: confirmPendingDeletion,
        onCancel: { pendingDeletion = nil }
      )
      .accessibilityIdentifier(ScreenAccessibilityID.storageScreen)
  }
}
