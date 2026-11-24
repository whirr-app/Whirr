import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import ReaderCore
import SwiftUI
import SyncEngine

/// The item detail screen. Artwork-adaptive, Apple-Music-style layout: large cover,
/// title/series/author/narrator/duration, a full-width play button coordinated with the resolved
/// pale/deep canvas (`CoverPaletteExtractor`/`CoverAmbientPalette`), a Chapters sheet, and a
/// trailing navigation-bar download bubble. The bubble uses native `ToolbarItem` placement, so
/// iOS 26 gives it Liquid Glass and the system morph transition on push/pop, with no custom glass
/// surface to police against `GlassEffectPolicy`.
///
/// The navigation title stays inline the whole time. A `.principal` toolbar item fades the book
/// title in once the hero has scrolled mostly past the bar, tracked via
/// `onScrollGeometryChange` rather than toggling `.navigationTitle` (which would re-layout and
/// flash on every crossing).
///
/// `extrasAccess`/`historyAccess` are required: production passes `AppEnvironment.dependencies`'
/// services, the harness its own fakes. The chapters and history sections show "unavailable" from
/// model state, never a missing dependency.
struct ItemDetailView: View {
  // All four models subscribe (two start network fetches) inside their own `init`. Building them
  // in `View.init` would dispatch that work on every re-evaluation of the `navigationDestination`
  // closure, with only the discarded model's `deinit` racing to cancel it. See `DeferredModel`.
  @State private var deferred = DeferredModel<Models>()
  @State private var isChaptersSheetPresented = false
  @State private var isHistorySheetPresented = false
  @State private var isSupplementsSheetPresented = false
  @State private var lookBack = PlayerLookBackController()
  @State private var metadataLayout: ItemDetailMetadataLayout?
  @State private var isInlineTitleRevealed = false
  /// The canvas the page is painted with, as opposed to the one its inputs currently compute.
  /// Adopts a palette that arrives after the first frame; see `AmbientCanvasLatch`.
  @State private var canvasLatch = AmbientCanvasLatch(adoptsLatePaletteOnArrival: true)
  @Environment(\.displayScale) private var displayScale
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let playback: PlaybackModel
  /// The stored app appearance resolved against the device, independent of reader themes.
  let effectiveAppColorScheme: ColorScheme

  /// Not `private`: shared with `ExpandedPlayerView.maximumCoverSize` in `NowPlayingMetadataTests`
  /// to confirm the two hero-cover surfaces land on the same quantized width.
  nonisolated static let coverDisplaySize: CGFloat = 272

  private let itemId: String
  private let seed: ItemSummary?
  private let library: any LibraryReading
  private let nativePodcastShowsReading: any NativePodcastShowsReading
  private let downloadReading: any DownloadReading
  private let downloadIntents: any DownloadIntents
  private let extrasAccess: any ItemDetailExtrasAccess
  private let historyAccess: any ListeningHistoryProviding
  private let requestLocalSessionUploadDrain: @concurrent @Sendable () async -> Void
  private let readerReading: any ReaderStateReading
  private let supplementReading: any ItemSupplementReading
  /// Read only to say "Available when online" for a PDF that is not on this device.
  private let connectivityModel: ConnectivityModel?
  private let tableOfContentsReading: any EPUBTableOfContentsReading
  private let contentsAccess: any EbookTableOfContentsAccess
  private let onPresentReader: (String, String, ItemMediaCategory) -> Void
  /// The Contents tab's own reader entry point: the same presentation, plus where in the book
  /// the tapped entry begins. Kept separate from `onPresentReader` so the five screens that
  /// raise the reader from a Read action keep their three-argument callback.
  private let onPresentReaderAtEntry: (String, String, ItemMediaCategory, ReaderRestoreTarget?) -> Void
  /// Pushes the semantic author, series, or narrator collection named by a hero credit.
  private let onOpenMetadata: (ItemMetadataLink) -> Void
  /// The screen-wide finished projection, read synchronously. No per-screen observation.
  private let finishedStatus: FinishedStatusStore
  /// The screen-wide saved membership and intent surface. Optional because the UI harness runs
  /// without it.
  private let actions: ItemActionsModel?
  /// The screen-wide download projection, read once to seed this screen's `ItemDownloadModel` so
  /// the toolbar bubble renders the right branch immediately. After that first frame the per-item
  /// observation takes over.
  private let downloadStatus: DownloadStatusStore?
  /// Builds the chapters sheet's bookmarks model; nil in the UI harness, which offers none.
  private let makeAudioBookmarksModel: ((String) -> AudioBookmarksModel)?

  /// The screen's models, resolved together. They share one `itemId` and one lifetime.
  private struct Models {
    let detail: ItemDetailModel
    let download: ItemDownloadModel
    let extras: ItemDetailExtrasModel
    let history: ItemHistoryModel
    let contents: ItemContentsModel
    let supplements: ItemSupplementsModel
  }

  private var models: Models {
    deferred.resolve {
      // Do not read `downloadCategory` here: it reads `model.state`, and `model` resolves this
      // same bundle, so it would recurse into `DeferredModel.resolve` until the stack is exhausted.
      // A seeded route supplies the category immediately; a cold route leaves it unknown until the
      // observed detail arrives.
      return Models(
        detail: ItemDetailModel(
          itemId: itemId, seed: seed, library: library,
          nativePodcastShowsReading: nativePodcastShowsReading, readerReading: readerReading),
        download: ItemDownloadModel(
          itemID: itemId, initialStatus: downloadStatus?.provisionalStatus(for: itemId),
          downloadReading: downloadReading, downloadIntents: downloadIntents),
        extras: ItemDetailExtrasModel(itemId: itemId, access: extrasAccess),
        history: ItemHistoryModel(
          itemId: itemId, category: seed?.category, history: historyAccess,
          uploadDrain: { [requestLocalSessionUploadDrain] in
            await requestLocalSessionUploadDrain()
          }),
        contents: ItemContentsModel(
          itemId: itemId, readerReading: readerReading, tableOfContents: tableOfContentsReading,
          contentsAccess: contentsAccess),
        supplements: ItemSupplementsModel(
          itemID: itemId, reading: supplementReading, downloadIntents: downloadIntents))
    }
  }

  private var model: ItemDetailModel { models.detail }
  private var downloadModel: ItemDownloadModel { models.download }
  private var extrasModel: ItemDetailExtrasModel { models.extras }
  private var historyModel: ItemHistoryModel { models.history }
  private var contentsModel: ItemContentsModel { models.contents }
  private var supplementsModel: ItemSupplementsModel { models.supplements }

  private var downloadCategory: ItemMediaCategory {
    if case .loaded(let item) = model.state { return item.category }
    return seed?.category ?? .audiobook
  }

  private var downloadHasReadableEbook: Bool {
    if case .loaded(let item) = model.state { return item.hasReadableEbook }
    return seed?.hasReadableEbook ?? false
  }

  init(
    itemId: String, seed: ItemSummary? = nil, library: any LibraryReading,
    nativePodcastShowsReading: any NativePodcastShowsReading,
    coverClient: any ArtworkServing, paletteService: CoverPaletteService, playback: PlaybackModel,
    downloadReading: any DownloadReading, downloadIntents: any DownloadIntents,
    extrasAccess: any ItemDetailExtrasAccess,
    historyAccess: any ListeningHistoryProviding,
    finishedStatus: FinishedStatusStore,
    actions: ItemActionsModel? = nil,
    requestLocalSessionUploadDrain: @escaping @concurrent @Sendable () async -> Void = {},
    downloadStatus: DownloadStatusStore? = nil,
    makeAudioBookmarksModel: ((String) -> AudioBookmarksModel)? = nil,
    readerReading: any ReaderStateReading = NoOpReaderStateReading(),
    supplementReading: any ItemSupplementReading = NoOpItemSupplementReading(),
    connectivityModel: ConnectivityModel? = nil,
    tableOfContentsReading: any EPUBTableOfContentsReading = NoOpEPUBTableOfContentsReading(),
    contentsAccess: any EbookTableOfContentsAccess = NoOpEbookTableOfContentsAccess(),
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void = { _, _, _ in },
    onPresentReaderAtEntry:
      @escaping (String, String, ItemMediaCategory, ReaderRestoreTarget?) ->
      Void = { _, _, _, _ in },
    onOpenMetadata: @escaping (ItemMetadataLink) -> Void = { _ in },
    effectiveAppColorScheme: ColorScheme = .dark
  ) {
    self.itemId = itemId
    self.onOpenMetadata = onOpenMetadata
    self.finishedStatus = finishedStatus
    self.actions = actions
    self.downloadStatus = downloadStatus
    self.makeAudioBookmarksModel = makeAudioBookmarksModel
    self.seed = seed
    self.tableOfContentsReading = tableOfContentsReading
    self.contentsAccess = contentsAccess
    _metadataLayout = State(initialValue: seed.map { ItemDetailMetadataLayout(item: $0) })
    self.library = library
    self.nativePodcastShowsReading = nativePodcastShowsReading
    self.downloadReading = downloadReading
    self.downloadIntents = downloadIntents
    self.extrasAccess = extrasAccess
    self.historyAccess = historyAccess
    self.requestLocalSessionUploadDrain = requestLocalSessionUploadDrain
    self.readerReading = readerReading
    self.supplementReading = supplementReading
    self.connectivityModel = connectivityModel
    self.onPresentReader = onPresentReader
    self.onPresentReaderAtEntry = onPresentReaderAtEntry
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.playback = playback
    self.effectiveAppColorScheme = effectiveAppColorScheme
  }

  private var ambientCanvas: AmbientCanvas {
    canvasLatch.resolve(
      itemID: itemId,
      palette: paletteService.palette(forItem: itemId),
      appearance: effectiveAppColorScheme,
      increasedContrast: colorSchemeContrast == .increased)
  }

  /// The live control tint resolved for the canvas rather than inherited from the player.
  private var accent: Color {
    ambientCanvas.accent
  }

  /// This title's server-synced finished state, a synchronous read of the screen-wide projection.
  private var isFinished: Bool {
    finishedStatus.isFinished(itemId)
  }

  /// The same derivation the tabs, the download bubble, and the read affordance already share, so
  /// the toolbar cannot decide a PDF sidecar is an ebook when the page below it says otherwise.
  private var capability: ItemMediaCapability {
    ItemMediaCapability.derive(
      category: downloadCategory, hasReadableEbook: downloadHasReadableEbook)
  }

  /// Saved for Later, in the toolbar so the action row carries the primary action alone at full
  /// width.
  private func savedToolbarButton(actions: ItemActionsModel) -> some View {
    let isSaved = actions.isSaved(itemID: itemId)
    let entry = ItemContextMenuPresentation.savedEntry(isSaved: isSaved)
    return Button {
      Task {
        if isSaved {
          await actions.removeFromSaved(itemID: itemId)
        } else {
          await actions.saveForLater(itemID: itemId)
        }
      }
    } label: {
      Image(systemName: entry.systemImage)
        .contentTransition(.symbolEffect(.replace))
        .foregroundStyle(.primary)
    }
    .animation(.snappy(duration: 0.28), value: isSaved)
    .accessibilityLabel(entry.title)
    .accessibilityHint(
      isSaved
        ? "Removes this title from Saved for Later."
        : "Saves this title to Saved for Later.")
  }

  /// The overflow menu. It presents `ItemContextMenuContent`, the rows the long-press menu builds
  /// from the same policies, narrowed by `BookMenuSurface.itemDetail` to the entries this screen
  /// has no control for. Play, Save for Later, the download and the author and narrator links are
  /// already on screen, which leaves the queue pair and the progress actions. Look Back and
  /// Listening History lead it when they apply.
  ///
  /// Never empty: `MediaProgressActionPolicy.actions` returns at least one entry per playback
  /// status (an unstarted ebook has only Mark as Finished). The button stays rather than coming
  /// and going with state.
  private func overflowMenu(item: ItemSummary, actions: ItemActionsModel) -> some View {
    Menu {
      // The player's Look Back, for the book that is loaded or a cold launch restored: it reads
      // back from that playhead.
      let offersLookBack = PlayerLookBackPresentation.isOffered(
        itemID: item.serverItemId, episodeID: nil, loadedItemID: playback.loadedItemID,
        loadedEpisodeID: playback.loadedEpisodeID,
        isRestoredAudiobook: playback.isRestoredAudiobook(itemID: item.serverItemId))
      if offersLookBack {
        Button {
          Task { await lookBack.show(itemID: item.serverItemId, playback: playback) }
        } label: {
          Label(LookBackCopy.menuTitle, systemImage: LookBackCopy.menuSymbol)
        }
      }
      if historyModel.tracksListeningHistory {
        Button {
          isHistorySheetPresented = true
        } label: {
          Label(MediaActionCopy.listeningHistory.title, systemImage: MediaActionCopy.listeningHistory.systemImage)
        }
      }
      if offersLookBack || historyModel.tracksListeningHistory {
        Divider()
      }
      ItemContextMenuContent(
        itemID: itemId,
        author: item.author,
        duration: item.durationSeconds,
        category: item.category,
        hasReadableEbook: item.hasReadableEbook,
        // Only a title with no audio at all can be removed from Continue Reading. Anything with
        // an audio file keeps the listening wording.
        usesEbookProgress: capability == .ebook,
        episodeID: nil,
        playbackStatus: { finishedStatus.playbackStatus(itemId) },
        showsNarratorLink: item.category == .audiobook,
        narratorLabel: ItemContextMenuPresentation.narratorLabel(item.narratorName),
        playback: playback,
        actions: actions,
        placement: .itemDetail,
        bookSurface: .itemDetail,
        onOpen: {},
        onRead: { onPresentReader(item.serverItemId, item.title, item.category) },
        // The menu hands back one whole credit string. This screen supplied the author, so
        // anything else came from the narrator row. Both are comma-joined lists and a name-keyed
        // destination resolves one name, so the first credit is what opens.
        onSearch: { credit in
          let role: ItemMetadataPersonRole = credit == item.author ? .author : .narrator
          guard let link = ItemMetadataLinkPresentation.personLinks(credit, role: role).first
          else { return }
          onOpenMetadata(link)
        })
    } label: {
      Image(systemName: "ellipsis")
        .foregroundStyle(.primary)
    }
    .menuIndicator(.hidden)
    .accessibilityLabel("More actions")
    .accessibilityHint("Shows playback, saved, navigation, download, and progress actions.")
  }

  var body: some View {
    detailSheets(pageAlerts)
  }

  /// The page's system chrome: its title, toolbar, and the ink the canvas resolves.
  private var pageChrome: some View {
    itemContent
      .navigationTitle(navigationTitle)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { toolbarContent }
      .tint(accent)
      .environment(\.coverAccent, accent)
      .environment(\.ambientProgressFill, ambientCanvas.coverMark)
      .environment(\.colorScheme, ambientCanvas.mode.colorScheme)
      .environment(\.whirrMetadataLadder, ambientCanvas.metadataLadder)
      // Keyed to the adoption rather than the canvas and applied to the whole page, so a late
      // palette moves background, ink and tint together while one ready on the first frame paints
      // without a fade. Read after `ambientCanvas`, so it sees this body's adoption.
      .animation(
        PlayerMotion.ambientAdoptionAnimation(reduceMotion: reduceMotion),
        value: canvasLatch.adoptionGeneration
      )
  }

  /// The download alert, the shared action alert, and the sheet reset when the item unloads.
  private var pageAlerts: some View {
    pageChrome
      // Surfaces a failed download intent (item detail that doesn't validate, a purge that can't
      // complete), so the bubble does not look like a dead button. Every string is the model's.
      .alert(
        "Download",
        isPresented: Binding(
          get: { downloadModel.actionErrorMessage != nil },
          set: { isPresented in if isPresented == false { downloadModel.dismissActionError() } }
        )
      ) {
        Button("OK", role: .cancel) { downloadModel.dismissActionError() }
      } message: {
        Text(downloadModel.actionErrorMessage ?? "")
      }
      .itemActionErrorAlert(actions)
      // The sheets render only against a loaded item. An item that unloads mid-presentation
      // (deleted, or dropped by a sync) would otherwise leave a blank sheet whose retained rows can
      // still act on the removed item's id.
      .onChange(of: isDetailLoaded) { _, isLoaded in
        if isLoaded == false {
          isChaptersSheetPresented = false
          isHistorySheetPresented = false
          isSupplementsSheetPresented = false
          lookBack.discard()
        }
      }
  }

  /// The loaded item's content: its scroll page, or the loading and not-found states.
  private var itemContent: some View {
    Group {
      switch model.state {
      case .loading:
        LoadingStateView(message: "Loading…")
      case .notFound:
        EmptyStateView(
          title: "Item Not Found",
          message: "This item is no longer in your synced library.",
          systemImage: "questionmark.folder"
        )
      case .loaded(let item):
        ItemDetailScrollContentView(
          item: item,
          coverClient: coverClient,
          paletteService: paletteService,
          ambientCanvas: ambientCanvas,
          playback: playback,
          extrasModel: extrasModel,
          readAffordance: model.readAffordance,
          readAffordanceCopy: model.readAffordanceCopy,
          actionLayout: model.actionLayout(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize),
          isFinished: isFinished,
          displayScale: displayScale,
          reduceMotion: reduceMotion,
          onPresentReader: onPresentReader,
          onPresentChapters: { isChaptersSheetPresented = true },
          supplements: supplementsModel.supplements,
          isOffline: ItemSupplementPresentation.isOffline(connectivityModel?.reachability),
          onPresentSupplements: { isSupplementsSheetPresented = true },
          onOpenMetadata: onOpenMetadata,
          metadataLayout: $metadataLayout,
          isInlineTitleRevealed: $isInlineTitleRevealed
        )
        .task(id: item.category) {
          historyModel.updateCategory(item.category)
        }
      }
    }
  }

  /// The reader tip and the three sheets, which only render against a loaded item.
  private func detailSheets<Content: View>(_ content: Content) -> some View {
    content
      .playerLookBackSheet(
        lookBack, itemID: itemId, playback: playback,
        accent: TranscriptAccent(ambientCanvas.primaryAction)
      )
      .sheet(isPresented: $isChaptersSheetPresented) {
        if case .loaded(let item) = model.state {
          ItemDetailChaptersSheet(
            item: item,
            extrasModel: extrasModel,
            playback: playback,
            contentsModel: contentsModel,
            isFinished: isFinished,
            actions: actions,
            makeBookmarksModel: makeAudioBookmarksModel,
            onSelectChapter: { chapter in
              Task {
                await playback.startOrSeek(
                  itemID: item.serverItemId, toGlobalOffset: chapter.start)
              }
            },
            onSelectBookmark: { bookmark in
              Task {
                await playback.startOrSeek(
                  itemID: item.serverItemId, toGlobalOffset: bookmark.time)
              }
            },
            onPresentReaderAtEntry: onPresentReaderAtEntry
          )
          .adaptiveSheetPresentation(role: .form)
        }
      }
      // The companion PDFs: a third sheet beside chapters and history, not a peer of Play/Read.
      .sheet(isPresented: $isSupplementsSheetPresented) {
        SupplementsSheet(model: supplementsModel, connectivityModel: connectivityModel)
          .adaptiveSheetPresentation(role: .page)
      }
      .sheet(isPresented: $isHistorySheetPresented) {
        if case .loaded(let item) = model.state {
          ItemDetailHistorySheet(
            historyModel: historyModel,
            onSelectEntry: { entry in
              Task {
                await playback.startOrSeek(
                  itemID: item.serverItemId, toGlobalOffset: entry.startPosition)
              }
              isHistorySheetPresented = false
            },
            onClose: { isHistorySheetPresented = false }
          )
          .adaptiveSheetPresentation(role: .form)
          .task {
            historyModel.updateCategory(item.category)
            await historyModel.refresh()
          }
        }
      }
  }

  /// The trailing toolbar: the fades-in title, Saved for Later, the download bubble, and the
  /// overflow menu.
  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    // Always present; only its opacity is scroll-driven, so the title fades without re-laying
    // out.
    ToolbarItem(placement: .principal) {
      Text(navigationTitle)
        .font(.headline)
        .lineLimit(1)
        .opacity(isInlineTitleRevealed ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isInlineTitleRevealed)
    }
    // [bookmark] [download] [ellipsis] in neutral ink (the screen's `.tint(accent)` would colour
    // two of them); orange from `DownloadControlRole` means the transfer needs the listener.
    //
    // Order keeps the group still as the screen settles: the bookmark and bubble withhold
    // themselves until resolved and a trailing group grows leftward, so declaring them before
    // the always-present ellipsis lets a late arrival extend the group, not shift it.
    if case .loaded = model.state, let actions, actions.hasResolvedSavedMembership,
      capability != .unsupportedDocument
    {
      ToolbarItem(placement: .topBarTrailing) {
        savedToolbarButton(actions: actions)
      }
    }
    // Never render the model's `.notDownloaded` placeholder: for a completed download it
    // flashes a download arrow before the trash control arrives. The warm seed makes this true
    // at construction on an ordinary push, so it only withholds the bubble on a cold launch
    // straight into detail.
    if case .loaded = model.state, downloadModel.hasResolvedInitialStatus,
      capability.supportsDownload
    {
      ToolbarItem(placement: .topBarTrailing) {
        ItemDetailDownloadBubbleView(
          model: downloadModel, category: downloadCategory,
          hasReadableEbook: downloadHasReadableEbook)
      }
    }
    if case .loaded(let item) = model.state, let actions, capability != .unsupportedDocument {
      ToolbarItem(placement: .topBarTrailing) {
        overflowMenu(item: item, actions: actions)
      }
    }
  }

  private var navigationTitle: String {
    if case .loaded(let item) = model.state { return item.title }
    return ""
  }

  private var isDetailLoaded: Bool {
    if case .loaded = model.state { return true }
    return false
  }
}
