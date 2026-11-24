import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

extension PodcastShowViewPresentation {
  static func notFoundMessage(for itemID: String) -> String {
    if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil {
      return "This podcast is not subscribed on this device."
    }
    return "This podcast is no longer in your synced library."
  }
}

struct PodcastShowView: View {
  @State private var deferredShow = DeferredModel<PodcastShowModel>()
  @State private var deferredItem = DeferredModel<ItemDetailModel>()
  @State var homeWashProvider: HomeWashProvider
  /// How far the wash has been scrolled away. A reference, never read in this screen's own
  /// `body` (see `pageBackground`).
  @State private var washOffset = PodcastShowWashOffset()
  @State var editMode: EditMode = .inactive
  @State var selection = BatchSelectionController<String, MediaItemAction>()
  @State var isSelectingForShowSave = false
  @State var isShowingSelectionFailure = false
  @State var selectionConfirmationMessage = ""
  @State var pendingBulkMark: PendingBulkMark?
  /// Set while the state glyph's explanation is up. The glyph says "something is off"; the
  /// sentence behind it says what.
  @State var isShowingStateExplanation = false
  /// Whether the header's title is on screen. A reference read only by `PodcastShowBarTitle`: it
  /// flips mid scroll, and a `@State Bool` here would rebuild the whole list at each crossing.
  @State private var barTitleState = PodcastShowBarTitleState()
  @State var isConfirmingUnsubscribe = false
  @State var serverRemovalConfirmation: NativeEpisodeServerSaveRemovalConfirmation?
  /// Whichever row's failed-download control was tapped last; one alert host for the whole list.
  @State var downloadFailureAlert: PodcastDownloadFailurePresentation.Alert?
  @Environment(\.dismiss) var dismiss
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @State private var availableWidth: CGFloat = 0

  let itemID: String
  let seed: ItemSummary?
  let library: any LibraryReading
  let nativePodcastShowsReading: any NativePodcastShowsReading
  let coverClient: any ArtworkServing
  let paletteService: CoverPaletteService
  let followedShowArtworkSources: FollowedShowArtworkSources?
  /// Read once for the whole list, never per row. The availability policy only needs the player's
  /// deduplicated Now Playing identity.
  let playback: PlaybackModel
  let makeModel: () -> PodcastShowModel
  let onSearch: (String) -> Void
  /// The row's tap presents the episode card rather than playing. See `PodcastShowContentView`
  /// for the row's `onSelect` callback.
  let onPresentEpisode: (NavigationModel.PodcastEpisodeRef) -> Void
  /// The overflow's "Show Settings" row. `LibraryShellView` installs
  /// `PodcastShowViewPresentation.showSettingsDestination(itemID:)` through
  /// `NavigationModel.navigate(to:)`, as every other Settings entry point does.
  let onOpenShowSettings: (String?) -> Void
  var refreshOnAppear = true

  @Environment(\.displayScale) var displayScale

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  private var coverSize: CGFloat {
    PodcastsViewPresentation.headerArtworkSize(
      horizontalSizeClass: horizontalSizeClass,
      verticalSizeClass: verticalSizeClass,
      isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  /// Artwork and wash share one request per size-class pair, independent of the drawn frame and
  /// of the accessibility size, so only crossing between the compact and regular header refetches.
  var artworkDisplaySize: CGFloat {
    PodcastsViewPresentation.headerArtworkRequestSize(
      horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass)
  }

  init(
    itemID: String,
    seed: ItemSummary? = nil,
    library: any LibraryReading,
    nativePodcastShowsReading: any NativePodcastShowsReading,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    followedShowArtworkSources: FollowedShowArtworkSources? = nil,
    playback: PlaybackModel,
    makeModel: @escaping () -> PodcastShowModel,
    onSearch: @escaping (String) -> Void,
    onPresentEpisode: @escaping (NavigationModel.PodcastEpisodeRef) -> Void,
    onOpenShowSettings: @escaping (String?) -> Void,
    refreshOnAppear: Bool = true
  ) {
    self.itemID = itemID
    self.seed = seed
    self.library = library
    self.nativePodcastShowsReading = nativePodcastShowsReading
    self.coverClient = coverClient
    self.paletteService = paletteService
    self.followedShowArtworkSources = followedShowArtworkSources
    self.playback = playback
    self.makeModel = makeModel
    self.onSearch = onSearch
    self.onPresentEpisode = onPresentEpisode
    self.onOpenShowSettings = onOpenShowSettings
    self.refreshOnAppear = refreshOnAppear
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        // The environment is not readable here. The compact request is the shared card variant;
        // each `request` below passes the size-class request, which replaces it.
        displaySize: PodcastsViewPresentation.headerArtworkRequestSize(
          horizontalSizeClass: .compact, verticalSizeClass: nil),
        displayScale: 1, artworkRole: .homeCard))
  }

  var model: PodcastShowModel {
    deferredShow.resolve(makeModel)
  }

  private var itemModel: ItemDetailModel {
    deferredItem.resolve {
      ItemDetailModel(
        itemId: itemID, seed: seed, library: library,
        nativePodcastShowsReading: nativePodcastShowsReading)
    }
  }

  var body: some View {
    pageFeedbackAndTasks(serverSaveSheets(pageSelectionAlerts(pageSelection)))
  }

  /// The selection chrome and the two selection resets, before any alert or task.
  private var pageSelection: some View {
    content
      .disabled(selection.isPerforming)
      .selectionChrome(
        isSelecting: editMode.isEditing,
        selectionTitle: selectionTitle,
        title: PodcastShowViewPresentation.navigationTitle(
          showTitle: (loadedItem ?? seed)?.title),
        titleDisplayMode: .inline
      )
      .toolbar { screenToolbar }
      .toolbar { barTitle }
      .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
      .hidesPlayerAccessory(whileSelecting: editMode.isEditing)
      .environment(\.editMode, $editMode)
      .navigationBarBackButtonHidden(editMode.isEditing)
      .onChange(of: editMode) { _, mode in
        if !mode.isEditing {
          selection.selected.removeAll()
          model.serverSave.disarmShowSave()
          isSelectingForShowSave = false
        }
      }
      .onChange(of: visibleEpisodeIDs) { _, ids in
        selection.selected.formIntersection(ids)
      }
  }

  struct PageWashTaskKey: Hashable {
    let itemID: String
    let source: ArtworkSource?
    let revision: ArtworkRevision
  }

  /// The loaded show, else the row that was tapped: both carry the revision every other surface
  /// keys this show's cover by.
  private var pageArtworkRevision: ArtworkRevision {
    (loadedItem ?? seed)?.artworkRevision ?? .unversioned
  }

  var pageWashSubject: EditorialWashSubject {
    EditorialWashSubject(
      itemID: PodcastShowViewPresentation.washKey(for: itemID),
      artworkSource: resolvedPageArtworkSource, artworkRevision: pageArtworkRevision)
  }

  var loadedItem: ItemSummary? {
    guard case .loaded(let item) = itemModel.state else { return nil }
    return item
  }

  private var resolvedPageArtworkSource: ArtworkSource? {
    PodcastShowViewPresentation.pageArtworkSource(
      seed: seed,
      resolverSource: followedShowArtworkSources?.source(for: itemID),
      loadedItem: loadedItem)
  }

  var pageWashTaskKey: PageWashTaskKey {
    PageWashTaskKey(
      itemID: itemID, source: resolvedPageArtworkSource, revision: pageArtworkRevision)
  }

  private var content: some View {
    let placeholder = PodcastShowViewPresentation.screenPlaceholder(for: itemModel.state)

    return
      episodeList
      // An overlay, not content: the screen placeholder must never add height to the scroll host.
      .overlay {
        if let placeholder {
          screenPlaceholderView(placeholder)
            .allowsHitTesting(placeholder.allowsHitTesting)
        }
      }
      .refreshable { await model.refresh() }
  }

  /// The list itself: the header and rows, and the scroll measurements the page background reads.
  private var episodeList: some View {
    // A nil binding in browsing mode preserves the row's ordinary long-press context menu.
    return List(selection: editMode.isEditing ? $selection.selected : nil) {
      if case .loaded(let item) = itemModel.state {
        PodcastShowContentView(
          model: model,
          item: item,
          palette: showPalette,
          itemID: itemID,
          availableWidth: availableWidth,
          horizontalSizeClass: horizontalSizeClass,
          coverClient: coverClient,
          playback: playback,
          artworkDisplaySize: artworkDisplaySize,
          coverSize: coverSize,
          onSearch: onSearch,
          onPresentEpisode: onPresentEpisode,
          onOpenShowSettings: onOpenShowSettings,
          onRequestUnsubscribe: { isConfirmingUnsubscribe = true },
          onDownloadFailure: { status, episodeID, isAvailableOnServer in
            downloadFailureAlert = PodcastDownloadFailurePresentation.alert(
              for: status, episodeID: episodeID, isAvailableOnServer: isAvailableOnServer)
          },
          onRequestServerRemoval: { serverRemovalConfirmation = .init(episodeID: $0) },
          onHeaderTitleVisibilityChange: { barTitleState.setHeaderTitleVisible($0) }
        )
        .onAppear {
          homeWashProvider.request(
            [item.washSubject], intent: .visible,
            displaySize: artworkDisplaySize, displayScale: displayScale, artworkRole: .homeCard)
        }
      }
    }
    // A ForEach forwards this identifier to its rows and their controls. Keep it on the
    // collection itself so automation can address the list without replacing row identities.
    .accessibilityIdentifier(PodcastAccessibilityID.episodeList)
    .listStyle(.plain)
    // The header's spacer and synopsis continuation rows are shorter than the default minimum.
    .environment(\.defaultMinListRowHeight, 0)
    .scrollDismissesKeyboard(.interactively)
    .scrollContentBackground(.hidden)
    .background(pageBackground)
    // Completion is observed on the List so the list can remain scrollable during the batch;
    // attaching this to the long outer modifier chain can exceed SwiftUI's type-checker limit.
    .onChange(of: model.serverSave.batchServerSaveCompletionVersion) { _, _ in
      selection.selected.removeAll()
      withAnimation { editMode = .inactive }
    }
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.width
    } action: { _, width in
      availableWidth = width
    }
    // The transform is what bounds the cost: it clamps, so past the wash's own height the value
    // stops changing and the action stops firing. `washOffset` is a reference, so writing it does
    // not invalidate this body (see `pageBackground`).
    .onScrollGeometryChange(for: CGFloat.self) { geometry in
      PodcastShowViewPresentation.washOffset(
        contentOffsetY: geometry.contentOffset.y, topInset: geometry.contentInsets.top)
    } action: { _, offset in
      washOffset.value = offset
    }
    .primaryScrollEdgeEffect(isSelecting: editMode.isEditing)
    .selectionMarkTint(isSelecting: editMode.isEditing)
  }

  /// Resolved once per body pass and read by both the page background and the content. A miss
  /// (no record yet, or a cover too grey to yield one) is the neutral wash, whose palette paints
  /// no region, so the uncoloured page is an ordinary path.
  private var showPalette: PodcastShowViewPresentation.ShowPalette {
    let wash = homeWashProvider.wash(for: pageWashSubject)
    return PodcastShowViewPresentation.palette(for: wash)
  }

  /// The editorial page, with the show's wash across its top region and behind the navigation bar,
  /// so it reads as the page's colour, not a band below the chrome. The wash travels with the
  /// list: screen-anchored it would stay put as the list scrolls through it, and as the header
  /// row's background it would leave the bar strip plain (no cell reaches behind the bar).
  /// Translating a screen background by the scroll offset does both, so this screen observes
  /// scroll geometry, bounded:
  ///
  /// - The offset is clamped to the wash's height, so scrolling past it produces no new values.
  /// - It lives in a reference type read only by `PodcastShowWashBackground`; a `@State CGFloat`
  ///   would invalidate `PodcastShowView.body` and the whole `List` every scroll frame.
  private var pageBackground: some View {
    PodcastShowWashBackground(wash: showPalette.headerWash, offset: washOffset)
  }

  @ViewBuilder
  private func screenPlaceholderView(
    _ placeholder: PodcastShowViewPresentation.ScreenPlaceholder
  ) -> some View {
    switch placeholder {
    case .loading:
      LoadingStateView(message: "Loading podcast…")
    case .notFound:
      EmptyStateView(
        title: "Podcast Not Found",
        message: PodcastShowViewPresentation.notFoundMessage(for: itemID),
        systemImage: "questionmark.folder")
    }
  }

  /// What the bar shows, as opposed to `navigationTitle`, which the back button and its history
  /// menu read and so names the show throughout. Always present outside selection, with only its
  /// opacity following the header, so the bar never re-lays-out as the header crosses it and has
  /// nothing to clip while the toolbar group morphs during the push.
  @ToolbarContentBuilder private var barTitle: some ToolbarContent {
    if !editMode.isEditing {
      ToolbarItem(placement: .principal) {
        PodcastShowBarTitle(
          title: PodcastShowViewPresentation.navigationTitle(
            showTitle: (loadedItem ?? seed)?.title),
          screenPlaceholder: PodcastShowViewPresentation.screenPlaceholder(for: itemModel.state),
          state: barTitleState)
      }
    }
  }

  var stateIndicator: PodcastShowViewPresentation.StateIndicator? {
    PodcastShowViewPresentation.stateIndicator(for: model.state)
  }

  /// Sits beside the options menu rather than in the list: a toolbar item can come and go without
  /// moving any episode row. The glyph carries the fact; a tap carries the sentence.
  func stateIndicatorButton(
    _ indicator: PodcastShowViewPresentation.StateIndicator
  ) -> some View {
    Button {
      isShowingStateExplanation = true
    } label: {
      Image(systemName: indicator.systemImage)
    }
    .accessibilityLabel(indicator.title)
    .accessibilityHint(indicator.message)
    .accessibilityIdentifier(PodcastAccessibilityID.showStateIndicator)
  }

  /// The trailing control is one options menu rather than a row of buttons. Viewing the queue
  /// belongs to the player alone, so this screen does not observe it. Server diagnostics live in
  /// Show Settings, not on this page.
  var optionsMenu: some View {
    return Menu {
      let counts = model.showMenuCounts
      let items = PodcastShowViewPresentation.showMenu(
        filter: model.filter,
        unplayedCount: counts.unplayed,
        playedCount: counts.played,
        downloadableCount: counts.downloadable,
        removableCount: counts.removable,
        isSearchActive: LibraryQuickFilter.isEffective(model.episodeQuery),
        isNativeFeed: model.isNativeFeed,
        offersSaveShow: model.serverSave.offersSaveShow)
      ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
        if index > 0, items[index - 1].group != item.group {
          Divider()
        }
        Button(role: item.isDestructive ? .destructive : nil) {
          perform(showMenuItem: item)
        } label: {
          if let systemImage = item.systemImage {
            Label(item.label, systemImage: systemImage)
          } else {
            Text(item.label)
          }
        }
        .disabled(item.isEnabled == false)
        .accessibilityHint(item.hint)
      }
    } label: {
      Label("Podcast Options", systemImage: "ellipsis")
    }
    .accessibilityIdentifier(PodcastAccessibilityID.showOptions)
  }

  /// A pending bulk mark, held while its confirmation alert is up. Below the threshold nothing is
  /// held and the action runs straight away.
  struct PendingBulkMark: Identifiable {
    enum Kind: Equatable {
      case markPlayed
      case markUnplayed
      case removeDownloads
    }
    let kind: Kind
    let message: String
    var id: Kind { kind }
    var isDestructive: Bool { kind == .removeDownloads }
    var confirmLabel: String {
      switch kind {
      case .markPlayed: "Mark as Played"
      case .markUnplayed: "Mark as Unplayed"
      case .removeDownloads: StorageCopy.confirmRemove
      }
    }
  }

  private func perform(showMenuItem item: PodcastShowViewPresentation.ShowMenuItem) {
    switch PodcastShowMenuAction(rawValue: item.id) {
    case .markAllPlayed:
      requestMarkAll(isFinished: true)
    case .markAllUnplayed:
      requestMarkAll(isFinished: false)
    case .downloadAll:
      // Not destructive, and the transfer cap and cellular opt-in already govern the cost.
      Task { await model.downloadAllInFilter() }
    case .removeAllDownloads:
      requestRemoveAllDownloads()
    case .openSettings:
      let title: String? = if case .loaded(let item) = itemModel.state { item.title } else { nil }
      onOpenShowSettings(title)
    case .saveShow:
      beginShowSaveSelection()
    case .unsubscribe:
      isConfirmingUnsubscribe = true
    case nil:
      break
    }
  }

  private func requestMarkAll(isFinished: Bool) {
    let count = model.episodesToMark(isFinished: isFinished).count
    if let message = PodcastShowViewPresentation.markAllConfirmation(
      count: count, isFinished: isFinished)
    {
      pendingBulkMark = PendingBulkMark(
        kind: isFinished ? .markPlayed : .markUnplayed, message: message)
      return
    }
    Task { await confirm(isFinished ? .markPlayed : .markUnplayed) }
  }

  private func requestRemoveAllDownloads() {
    guard
      let message = PodcastShowViewPresentation.removeAllConfirmation(
        count: model.episodesToRemove().count)
    else { return }
    pendingBulkMark = PendingBulkMark(kind: .removeDownloads, message: message)
  }

  func confirm(_ kind: PendingBulkMark.Kind) async {
    switch kind {
    case .markPlayed: await model.markAllAsPlayed()
    case .markUnplayed: await model.markAllAsUnplayed()
    case .removeDownloads: await model.removeAllDownloadsInFilter()
    }
  }

}

/// How far the show's wash has been scrolled away, held outside `PodcastShowView`'s own state.
///
/// A scroll offset in `@State` rebuilds the screen's `body` (here, a whole `List`) every frame the
/// reader moves. Observation is per-property, so putting the value behind a reference and reading
/// it only in `PodcastShowWashBackground` confines invalidation to the view that depends on it.
/// Starts true: the header draws on the first frame, so the bar stays empty through the push.
@Observable final class PodcastShowBarTitleState {
  private(set) var isHeaderTitleVisible = true

  /// Ignores an unchanged value, so a repeated report notifies no one.
  func setHeaderTitleVisible(_ isVisible: Bool) {
    guard isVisible != isHeaderTitleVisible else { return }
    isHeaderTitleVisible = isVisible
  }
}

/// The show's name in the bar, faded by opacity alone so the bar never re-lays-out.
private struct PodcastShowBarTitle: View {
  let title: String
  let screenPlaceholder: PodcastShowViewPresentation.ScreenPlaceholder?
  let state: PodcastShowBarTitleState

  var body: some View {
    let isShown = PodcastShowViewPresentation.showsBarTitle(
      screenPlaceholder: screenPlaceholder, isHeaderTitleVisible: state.isHeaderTitleVisible)
    Text(title)
      .font(.headline)
      .lineLimit(1)
      .opacity(isShown ? 1 : 0)
      .animation(.easeInOut(duration: 0.2), value: isShown)
      .accessibilityHidden(!isShown)
  }
}

@Observable final class PodcastShowWashOffset {
  var value: CGFloat = 0
}

/// The washed page, translated by however far it has been scrolled.
///
/// The gradient is the page's, running to the top edge behind the navigation bar; the offset is
/// the list's, so it leaves with the header. No legibility rule of its own: `CoverWash` fixes both
/// variants' lightness, so label contrast can't flip with hue. Grey secondary ink does fall under
/// 4.5:1 on the dark variant at every hue, hence the header's secondary labels are `WashInk` and
/// it declares `drawnOnCoverWash`. It paints `pageColor`, never `cardColor`, whose strength is
/// faint in light and invisible in dark, as it earns separation across a hard edge this fade lacks.
private struct PodcastShowWashBackground: View {
  let wash: CoverWash?
  let offset: PodcastShowWashOffset

  var body: some View {
    ZStack(alignment: .top) {
      WhirrColorToken.editorialBackground.color
      if let wash {
        LinearGradient(
          stops: [
            Gradient.Stop(color: wash.pageColor, location: 0),
            Gradient.Stop(
              color: wash.pageColor,
              location: PodcastShowViewPresentation.headerWashSolidFraction),
            Gradient.Stop(color: WhirrColorToken.editorialBackground.color, location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: PodcastShowViewPresentation.headerWashHeight)
        .offset(y: -offset.value)
      }
    }
    .ignoresSafeArea()
  }
}
