import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

/// The full-screen expanded player (ARCHITECTURE.md §4/§6), presented through a UIKit-owned
/// transition: chapters, rate and sleep-timer controls, plus keyboard Space/arrow/Command-W.
/// Pure state-over-`PlaybackModel`/`PlaybackControlling` binding, like `MiniPlayerContainerView`;
/// every control forwards a `PlayerIntent`/`PlaybackModel` call.
///
/// Each readout that moves with the playhead lives in its own subview (`ListeningMetadataSection`,
/// `PlaybackTimelineSection`, `TransportRow`, `QuickActionsRow`, `StatusBannerSection`).
/// `PlaybackModel.currentTime` and `PlayerController.state` change every ~0.5s tick, so reading
/// either in this `body` would re-run the whole page (`GeometryReader`/`ScrollView`, the
/// `radius: 28` cover shadow, the gradient) several times a second and peg a core on device. This
/// `body` reads no per-tick value.
struct ExpandedPlayerView: View {
  let itemID: String
  /// The episode paired with `itemID` in the same committed presentation identity. It must not be
  /// read from live playback while the queue is transitioning.
  var episodeID: String? = nil
  /// Queue-row metadata for the committed identity, used only until live detail arrives.
  var metadataSeed: PlayerMetadataSeed? = nil
  let playback: PlaybackModel
  let connectivityModel: ConnectivityModel?
  let player: any PlaybackControlling
  let library: any LibraryReading
  let nativePodcastShowsReading: any NativePodcastShowsReading
  let coverClient: any ArtworkServing
  let navigation: NavigationModel
  /// The account's palette service, shared with `MiniPlayerContainerView` so both
  /// surfaces theme from one derivation per cover. This page opens on the mini-player's answer
  /// while its own item loads (`palette(forItem:)`).
  let paletteService: CoverPaletteService
  /// Shell-lifetime RSS artwork identity. Optional for standalone/test compositions that do not
  /// mount the Library shell; production always supplies the shell's resolver.
  var followedShowArtworkSources: FollowedShowArtworkSources? = nil
  /// The shell's observation of the playing episode's own image. Nil in compositions without one.
  var episodeArtwork: PlayerEpisodeArtwork? = nil
  /// The shell-scoped item actions shared with browse/search context menus. Reusing it keeps
  /// download state and progress failures consistent across every entry point.
  let actions: ItemActionsModel
  /// The shell-scoped owner of playback speed. Shared, not per-page: the speed this page
  /// sets is the same value Show Settings and the lock screen edit.
  let playbackRate: PlaybackRateCoordinator
  /// The shell's finished-state projection. Only the chapters sheet reads it, inside its own
  /// presented content, so a finished-state change never re-runs this page.
  let finishedStatus: FinishedStatusStore
  /// The shell-scoped metadata boundary used to resolve audiobook chapters before a playback
  /// session has prepared a `PlayerItem`.
  let extrasAccess: any ItemDetailExtrasAccess
  /// Resolves the displayed audiobook byline to the server author identity its Library route needs.
  let authorSeriesReading: any AuthorSeriesReading
  /// The universal Up Next model, built on first presentation of the queue sheet and held for this
  /// player's lifetime. A factory so the queue's GRDB observation opens only when asked for; held
  /// here because the post-Clear restore token must outlive the sheet's view identity.
  let makeListeningQueueModel: () -> ListeningQueueModel
  /// Builds the listening-history model for one item. A factory because `ItemHistoryModel.init`
  /// reads its cache and starts a refresh, so it waits until the history is requested. Takes the
  /// item id because this page outlives its item (`task(id: itemID)` re-seeds in place).
  let makeItemHistoryModel: (String) -> ItemHistoryModel
  /// Builds one audiobook's bookmark model. Absent in the standalone harness.
  var makeAudioBookmarksModel: ((String) -> AudioBookmarksModel)? = nil
  /// Builds the companion-PDF model for one audiobook. Absent in the standalone harness and the
  /// test compositions, where the overflow menu then offers no PDF entry.
  var makeSupplementsModel: ((String) -> ItemSupplementsModel)? = nil
  /// Nil (a harness) offers no transcript.
  var transcriptCoordinator: EpisodeTranscriptCoordinator? = nil
  /// The app appearance the ambient canvas resolves against, supplied by the shell. The UIKit host
  /// forces no interface style: the page follows the app and its polarity follows the artwork.
  /// Defaults to `.dark` (dark-safe) for the harness and tests.
  var effectiveAppColorScheme: ColorScheme = .dark
  /// The shell freezes/reconciles the committed identity at the queue sheet's presentation
  /// boundary. Defaults keep the standalone UI harness composition source-compatible.
  var onQueuePresented: () -> Void = {}
  var onQueueDismissed: () -> Void = {}
  var onPlayNowCommitted: (PlayerMetadataSeed) -> Void = { _ in }
  /// What View Details needs to raise an episode's card over this page: the card's model factory
  /// and the palette service its artwork draws from. Absent in the standalone harness and the test
  /// compositions, where an episode's View Details then goes nowhere.
  var episodeCard: PlayerEpisodeCardDependencies? = nil
  /// The shared search entry point, for the player-hosted card's More From Creator. A no-op in the
  /// same compositions that have no `episodeCard`.
  var onSearch: (String) -> Void = { _ in }

  @AppStorage(SkipIntervalConfiguration.forwardStorageKey)
  var storedForwardSkipSeconds = SkipIntervalConfiguration.defaultForwardSeconds
  @AppStorage(SkipIntervalConfiguration.backwardStorageKey)
  var storedBackwardSkipSeconds = SkipIntervalConfiguration.defaultBackwardSeconds
  @State var itemModel: ItemDetailModel?
  @State private var extrasModel: ItemDetailExtrasModel?
  @State private var isShowingChapters = false
  @State private var isShowingSleepTimer = false
  @State var isShowingUpNext = false
  @State var isShowingHistory = false
  /// The episode card View Details raised over this page, or `nil`. An item rather than a flag so
  /// the sheet is keyed by the episode it shows.
  @State var presentedEpisodeCard: NavigationModel.PodcastEpisodeRef?
  /// An episode card the Up Next sheet asked for, raised once that sheet has finished leaving:
  /// this page cannot present the card while it is still presenting the queue.
  @State var episodeCardAfterQueue: NavigationModel.PodcastEpisodeRef?
  @State var upNextDetent = ListeningQueuePresentation.initialDetent
  @State var deferredQueue = DeferredModel<ListeningQueueModel>()
  /// Built by `presentHistory()` and cleared whenever the page re-seeds onto another item, so it
  /// never answers for the previous title. Not a `DeferredModel`: that resolves once for the
  /// view's whole lifetime, and this page's lifetime spans more than one item.
  @State var historyModel: ItemHistoryModel?
  /// Rebuilt with the item it answers for, like `historyModel`. `nil` for a podcast episode.
  @State private var supplementsModel: ItemSupplementsModel?
  @State private var isShowingSupplements = false
  @State var bookmarks = PlayerBookmarkController()
  @State private var transcript = PlayerTranscriptController()
  @State private var lookBack = PlayerLookBackController()
  /// The measured natural height of the metadata band and status banner in the flexible upper
  /// region. Zero until the first layout pass reports it.
  @State private var upperContentHeight: CGFloat = 0
  @State var seekFeedback = SeekFeedbackState()
  @State var canvasLatch = Self.makeCanvasLatch()

  /// Adopts a palette that arrives after the page opens: on a cold launch the store can be empty
  /// when the player opens and the row lands moments later. A palette present on the first frame
  /// is final.
  static func makeCanvasLatch() -> AmbientCanvasLatch {
    AmbientCanvasLatch(adoptsLatePaletteOnArrival: true)
  }

  private struct ArtworkTaskID: Hashable {
    let itemID: String
    let source: ArtworkSource?
    let revision: ArtworkRevision
    /// Until the item loads, its source and revision are placeholders (`CoverPaletteIdentity`).
    let isProvisional: Bool
  }
  @Environment(\.displayScale) var displayScale
  @Environment(\.colorSchemeContrast) var colorSchemeContrast
  @Environment(\.dynamicTypeSize) var dynamicTypeSize
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  @Environment(\.verticalSizeClass) var verticalSizeClass

  /// Player chrome is semantic and neutral. The cover-derived colour belongs to the
  /// ambient canvas here; the item-detail screen continues to use the palette's accent for Resume.
  static let neutralControlTint = Color.primary

  /// Whether transport/scrubber should act (`ExpandedPlayerPresentation`): true for a live
  /// session and for a retained-but-not-yet-active item alike, since `play(itemID:)`/
  /// `skip(itemID:by:)`/`startOrSeek(itemID:toGlobalOffset:)` all prepare a session on
  /// demand. Reads only `playback.activeItemID`/`displayedItem`, neither of which ticks per
  /// progress event, so this is safe to read here in `body` rather than only in a leaf.
  private var isTransportEnabled: Bool {
    ExpandedPlayerPresentation.isTransportEnabled(
      itemID: itemID, episodeID: displayedEpisodeID, activeItemID: playback.activeItemID,
      activeEpisodeID: playback.activeEpisodeID, loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID, displayedItem: playback.displayedItem)
  }

  var displayedEpisodeID: String? {
    episodeID
  }

  private var displayedIdentity: SeekFeedbackState.Identity {
    SeekFeedbackState.Identity(itemID: itemID, episodeID: displayedEpisodeID)
  }

  var body: some View {
    pageSheetPresentation
  }

  /// The shared page chrome, before any per-item work or sheet. Split from `pageSheets` and
  /// `pageTasks` so no single property carries the whole modifier chain.
  private var pageChrome: some View {
    pageContent
      .tint(Self.neutralControlTint)
      .environment(\.coverAccent, Self.neutralControlTint)
      .environment(\.ambientProgressFill, ambientCanvas.coverMark)
      // Pinned from the canvas, as item detail pins it, so the page's ink and its semantic
      // colours are always read from the same answer.
      .environment(\.colorScheme, ambientCanvas.mode.colorScheme)
      .environment(\.whirrMetadataLadder, ambientCanvas.metadataLadder)
      .itemActionErrorAlert(actions)
      .playerBookmarkConfirmation(bookmarks)
      .overlay(alignment: .bottom) { SleepTimerRestartBanner(player: player) }
      .lookBackTipTrigger(isBook: episodeID == nil)
      .tracksEpisodeArtwork(episodeArtwork, itemID: itemID, episodeID: displayedEpisodeID)
  }

  /// Per-item work: the models the page re-seeds in place, and the one palette read per cover.
  private var pageTasks: some View {
    pageChrome
      .task(id: itemID) {
        // Protect the active item from bounded palette-cache eviction.
        paletteService.pin(itemID: itemID)
        // Do not let a previous item's chapter projection survive while this item's metadata is
        // resolving. A live PlayerItem still takes precedence once playback is prepared.
        extrasModel = nil
        // As with the chapter projection above: a retained history model answers for the item it
        // was built for. Dropping it here also cancels its refresh through `deinit`.
        historyModel = nil
        isShowingSupplements = false
        supplementsModel = episodeID == nil ? makeSupplementsModel?(itemID) : nil
        bookmarks.reset(itemID: itemID, episodeID: episodeID, makeModel: makeAudioBookmarksModel)
        itemModel = ItemDetailModel(
          itemId: itemID, library: library, nativePodcastShowsReading: nativePodcastShowsReading)
        extrasModel = ItemDetailExtrasModel(itemId: itemID, access: extrasAccess)
      }
      // Keyed on the resolved source as well as the item: a followed show whose source lands
      // after the first frame (cold launch) re-derives under its real key without rebuilding the
      // models above, and the owner's `sourceChanged` has already cleared whatever the placeholder
      // key left behind. Until the item loads the identity is provisional: it may show a saved row
      // but never saves one over the resolved row.
      .task(
        id: ArtworkTaskID(
          itemID: itemID, source: resolvedArtworkSource, revision: liveArtworkRevision,
          isProvisional: isItemLoaded == false)
      ) {
        let key = artworkPaletteKey
        let identity = paletteIdentity
        await paletteService.show(
          identity,
          bytes: .paletteSource(
            displayed: key, coverClient: coverClient))
        await paletteService.waitForPalette(identity)
      }
      .onChange(of: displayedIdentity) { _, _ in
        seekFeedback.cancelSkipEpisode()
      }
  }

  /// The sheets the page raises, in the order they present: the ones that belong to this page's
  /// own content first, then the queue and episode card that can interrupt it.
  private var pageSheets: some View {
    pageTasks
      .sheet(isPresented: $isShowingChapters) {
        PlayerChaptersSheet(
          itemID: itemID,
          episodeID: displayedEpisodeID,
          player: player,
          playback: playback,
          finishedStatus: finishedStatus,
          fallbackChapterMap: metadataChapterMap,
          bookmarksModel: bookmarks.model,
          actions: actions,
          isPresented: $isShowingChapters
        )
        .themedSheet(
          accent: Self.neutralControlTint, role: .form, detents: [.medium, .large])
      }
      .sheet(isPresented: $isShowingSleepTimer) {
        PlayerSleepTimerSheet(player: player)
          .themedSheet(
            accent: Self.neutralControlTint, role: .fitted,
            detents: PlayerSleepTimerSheet.compactDetents)
      }
      // Past sessions for this title, raised from the overflow menu. Same system sheet treatment
      // and detents as the chapters sheet: both list positions to jump to, and both may be long.
      .sheet(isPresented: $isShowingHistory) {
        PlayerHistorySheet(
          historyModel: historyModel,
          itemID: itemID,
          playback: playback,
          isPresented: $isShowingHistory
        )
        .themedSheet(
          accent: Self.neutralControlTint, role: .form, detents: [.medium, .large])
      }
      // The narrator's "see the accompanying PDF": raised over the page, so audio keeps playing.
      .sheet(isPresented: $isShowingSupplements) {
        if let supplementsModel {
          SupplementsSheet(model: supplementsModel, connectivityModel: connectivityModel)
            .themedSheet(accent: Self.neutralControlTint, role: .page, detents: [.large])
        }
      }
      .playerTranscriptSheet(
        transcript, coordinator: transcriptCoordinator, playback: playback, itemID: itemID,
        episodeID: displayedEpisodeID, accent: TranscriptAccent(ambientCanvas.primaryAction),
        chapters: transcriptChapters
      )
      .playerLookBackSheet(
        lookBack, itemID: itemID, playback: playback,
        accent: TranscriptAccent(ambientCanvas.primaryAction)
      )
  }

  /// The queue and View Details sheets, and the flag that decides whether the inline queue or
  /// its sheet is showing.
  private var pageSheetPresentation: some View {
    upNextSheetPresentation(pageSheets)
      // View Details on an episode. Raised here, over the page, like Chapters and History: the
      // shell cannot present its own card while presenting this player, and collapsing to reach it
      // lands on the section root before the card rises. Leaving the card for the show or for
      // search drops it, installs the destination behind the player, and collapses (as
      // `PlayerUpNextSheet.onOpen` does).
      .sheet(item: $presentedEpisodeCard) { ref in
        if let episodeCard {
          PlayerEpisodeCardSheet(
            ref: ref, dependencies: episodeCard, coverClient: coverClient,
            navigation: navigation, playback: playback,
            host: PodcastEpisodeCardHost(
              openShow: { route in
                presentedEpisodeCard = nil
                pushDetailsBehindThePlayer(route)
                navigation.collapsePlayer()
              },
              search: { query in
                presentedEpisodeCard = nil
                onSearch(query)
                navigation.collapsePlayer()
              })
          )
          // Same identity contract as the shell's card; see `LibraryShellView`'s note on why
          // `.sheet(item:)` alone does not give a re-presented card fresh `@State`.
          .id(ref.id)
        }
      }
      .onChange(of: isShowingUpNext) { _, isPresented in
        upNextVisibilityChanged(isPresented)
      }
  }

  /// Everything the player shows over the ambient background. The dismiss handle and upper content
  /// stay in the safe content region; the chrome spends the bottom container inset. The upper
  /// content owns the single scroll view; the chrome is its bottom-anchored sibling.
  private var pageContent: some View {
    // Resolved into a local first: reading the latch's adoption generation is only meaningful
    // after this pass's `resolve`, and an argument list would leave that ordering implicit.
    let canvas = ambientCanvas
    let adoptionGeneration = canvasLatch.adoptionGeneration
    let showsInlineQueue = InlineUpNextPresentation.isInlineShown(
      isShowingUpNext: isShowingUpNext, placement: upNextPlacement)
    return ExpandedPlayerLayoutView(
      widthClass: horizontalSizeClass == .regular ? .regular : .compact,
      isCompactHeight: verticalSizeClass == .compact,
      itemID: itemID,
      episodeID: displayedEpisodeID,
      title: title,
      author: author,
      playback: playback,
      connectivityModel: connectivityModel,
      player: player,
      coverClient: coverClient,
      // The resolved source, as the palette key above uses: the two must name one cover, or the
      // palette waits on a fetch the page never starts.
      artworkSource: resolvedArtworkSource,
      artworkFallbackSource: artworkResolution.fallbackSource,
      artworkRevision: liveArtworkRevision,
      metadataChapterMap: metadataChapterMap,
      isTransportEnabled: isTransportEnabled,
      bylineDestination: bylineDestination,
      onSelectByline: openByline,
      actions: actions,
      itemDetailDuration: itemDetailDuration,
      onShowHistory: presentHistory,
      supplementCount: supplementsModel?.supplements.count ?? 0,
      onShowSupplements: { isShowingSupplements = true },
      onAddBookmark: addBookmark,
      onViewDetails: openDetails,
      onShowTranscript: transcript.onShow,
      onShowLookBack: { Task { await lookBack.show(itemID: itemID, playback: playback) } },
      isShowingChapters: $isShowingChapters,
      fallbackTotalDuration: timelineFallbackDuration,
      timelineReadoutStyle: timelineReadoutStyle,
      seekFeedback: seekFeedback,
      playPauseFill: canvas.coverMark ?? accent,
      playbackRate: playbackRate,
      isShowingSleepTimer: $isShowingSleepTimer,
      isShowingUpNext: $isShowingUpNext,
      isShowingInlineQueue: showsInlineQueue,
      inlineQueue: showsInlineQueue ? upNextQueue(style: .inline) : nil,
      loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID,
      pageBackground: canvas.background,
      pageBackgroundAdoptionGeneration: adoptionGeneration,
      artworkInk: canvas.ink,
      dismissHandle: dismissHandle,
      keyboardShortcuts: keyboardShortcuts,
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
      upperContentHeight: $upperContentHeight
    )
  }

  /// The visible close affordance, on the keyboard shortcut's navigation path. A real `Button`: a
  /// shape with `.isButton` and `.accessibilityAction` reaches only VoiceOver's rotor, leaving
  /// the pull-down drag as the only pointer route off the page (SC 2.5.7). The 28pt container is
  /// measured by `ExpandedPlayerChromeLayoutTests` to find the content region.
  private var dismissHandle: some View {
    Button {
      navigation.collapsePlayer()
    } label: {
      Capsule()
        .fill(.primary.opacity(0.35))
        .frame(width: 36, height: 5)
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Close player")
    .accessibilityHint("Returns to the app with playback continuing.")
    .accessibilityIdentifier(PlayerAccessibilityID.expandedDismissHandle)
    .playerMorphHiddenWhileOpening()
  }

  // MARK: - Sections

  /// The item-detail fetch's own duration, and only that. It describes the show when this player
  /// is showing a podcast episode, so resolving what "Mark as Finished" should record is left to
  /// `ExpandedPlayerPresentation.finishDurationSeconds` in the leaf that can also see the live
  /// episode timeline.
  private var itemDetailDuration: Double? {
    if case .loaded(let item) = itemModel?.state {
      return item.durationSeconds
    }
    return nil
  }

  /// The displayed episode's chapters for the transcript's headings: the loaded session's once it
  /// is this episode, else the metadata's.
  private func transcriptChapters() -> [PlayerCore.PlaybackChapter] {
    let isLoaded = playback.loadedItemID == itemID && playback.loadedEpisodeID == displayedEpisodeID
    let loaded = isLoaded ? player.state.item?.chapters : nil
    return (loaded ?? metadataChapterMap)?.chapters ?? []
  }

  /// Metadata chapter markers are useful before playback prepares, but the loaded session remains
  /// authoritative once it exists. This value changes at most when the item-detail request
  /// resolves, never on the playhead tick.
  var metadataChapterMap: PlaybackChapterMap? {
    guard case .loaded(let extras) = extrasModel?.state else { return nil }
    return ExpandedPlayerPresentation.playbackChapterMap(from: extras)
  }

  private var timelineFallbackDuration: Double? {
    ExpandedPlayerPresentation.timelineDurationSeconds(
      itemID: itemID, episodeID: displayedEpisodeID, displayedItem: playback.displayedItem,
      itemDetailDurationSeconds: itemDetailDuration)
  }
}
