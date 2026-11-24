import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import ReaderCore
import SwiftUI
import SyncEngine

extension LibraryShellView {
  /// Entering search from another surface's affordance. `SearchView` mirrors the query into its
  /// own field, so that is not set here as well, and nothing asks for focus: the query is already
  /// typed, and a keyboard would only cover the results it just asked for.
  func showSearch(_ query: String) {
    navigation.showSearchRoot()
    searchModel.updateQuery(query)
  }

  /// Where every cross-show episode surface's `onSelectEpisode` callback ends up, as
  /// `select(_:artworkRole:displaySize:)` below is for item taps. The sheet owns its 72pt
  /// shared-wash request; opening it never waits for palette work.
  func selectEpisode(itemID: String, episodeID: String) {
    navigation.presentEpisode(.init(itemID: itemID, episodeID: episodeID))
  }

  /// Where every reader entry point ends up: the detail screen's Read bar, an ebook row's
  /// long-press Read entry, and Home's own rows.
  func presentReader(itemID: String, title: String, category: ItemMediaCategory) {
    raiseReader(ReaderPresentationItem(itemID: itemID, title: title, category: category))
  }

  /// The Contents tab's entry point: same presentation, plus the entry the reader tapped.
  func presentReader(
    itemID: String, title: String, category: ItemMediaCategory,
    initialTarget: ReaderRestoreTarget?
  ) {
    raiseReader(
      ReaderPresentationItem(
        itemID: itemID, title: title, category: category, initialTarget: initialTarget))
  }

  /// See `ReaderPresentationRelay`: a reader asked for from inside the regular-width item-detail
  /// card waits for that card's dismissal, because the cover carrying it is presented by an
  /// ancestor of the card's sheet. `presentedItemDetail` is nil at compact width, where detail is
  /// pushed instead, so that path raises the reader directly.
  func raiseReader(_ item: ReaderPresentationItem) {
    guard
      let immediate = readerRelay.request(
        item, itemDetailPresented: navigation.presentedItemDetail != nil)
    else {
      navigation.dismissItemDetail()
      return
    }
    onPresentReader = immediate
  }

  /// Runs from the item-detail card's `onDismiss`, once its transition has completed.
  func releaseReaderHeldByItemDetail() {
    guard let queued = readerRelay.itemDetailDismissed() else { return }
    onPresentReader = queued
  }

  /// Where every "resume this title" tap ends up, the listening counterpart of `presentReader`.
  /// The mini player appearing is the feedback; the card does not expand the player.
  func resumeListening(itemID: String, episodeID: String?) {
    Task {
      await playback.start(itemID: itemID, episodeID: episodeID)
    }
  }

  /// The player's listening-history model, built from the same boundary and upload drain as the
  /// item detail screen's History tab, since resuming from a Continue Listening row skips detail.
  /// Always `.audiobook`: the player only offers history for an item scope
  /// (`PlayerQuickActionsPresentation.showsHistory`).
  func makeItemHistoryModel(itemID: String) -> ItemHistoryModel {
    ItemHistoryModel(
      itemId: itemID, category: .audiobook, history: dependencies.historyAccess,
      uploadDrain: { [drain = dependencies.requestLocalSessionUploadDrain] in
        await drain()
      })
  }

  /// One audiobook's Audiobookshelf bookmarks for the expanded player.
  func makeAudioBookmarksModel(itemID: String) -> AudioBookmarksModel {
    AudioBookmarksModel(itemID: itemID, intents: dependencies.audioBookmarkIntents)
  }

  /// The companion-PDF model for one item, shared by item detail's row and the player's overflow
  /// entry so both read the same stored set and route a missing file through the same request.
  func makeSupplementsModel(itemID: String) -> ItemSupplementsModel {
    ItemSupplementsModel(
      itemID: itemID, reading: dependencies.supplementReading, downloadIntents: dependencies.downloadIntents)
  }

  /// Drives SwiftUI's native `tabViewBottomAccessory(isEnabled:content:)` visibility path so the
  /// system can add and remove its own host without rebuilding the `TabView` through two branches.
  var accessoryIsPresented: Bool {
    MiniPlayerAccessoryPresentation.isPresented(
      nowPlayingIdentity: playback.nowPlayingIdentity,
      isSelecting: selectionChrome.isSelecting)
  }

  /// Forms the `Binding<Bool>` the expanded player's UIKit presentation needs from
  /// `NavigationModel.playerPresentation` (`private(set)`), as `pathBinding(for:)` does over
  /// `navigation[pathFor:]`. The binding is the source of product state while the bridge owns
  /// presentation and interactive dismissal.
  var playerPresentationBinding: Binding<Bool> {
    let binding = PlayerPresentationBinding(navigation: navigation)
    return Binding(get: { binding.get }, set: { binding.set($0) })
  }

  func presentExpandedPlayer(seed: PlayerMetadataSeed?) {
    snapshotExpandedPlayerPresentation(seed: seed)
    navigation.expandPlayer()
  }

  /// Takes the cover-open snapshot as one identity value. The player must never combine this
  /// item's id with a live episode id while a queue transition is in flight. See
  /// `ExpandedPlayerPresentationState.snapshot(identity:metadataSeed:)` for which seed it keeps.
  func snapshotExpandedPlayerPresentation(seed: PlayerMetadataSeed? = nil) {
    guard let identity = playback.nowPlayingIdentity else { return }
    expandedPlayerPresentation.state.snapshot(identity: identity, metadataSeed: seed)
  }

  /// As `playerPresentationBinding`, over `NavigationModel.settingsPresentation`.
  var settingsPresentationBinding: Binding<Bool> {
    let binding = SettingsPresentationBinding(navigation: navigation)
    return Binding(get: { binding.get }, set: { binding.set($0) })
  }

  /// `.sheet(item:)` binding over `NavigationModel.presentedEpisode` (`private(set)`). The
  /// interactive swipe-down writes `nil` back through this, as a system dismissal does for
  /// `settingsPresentationBinding`. `playerPresentationBinding` is handled by the UIKit bridge,
  /// whose completed transition invokes shell cleanup.
  var presentedEpisodeBinding: Binding<NavigationModel.PodcastEpisodeRef?> {
    Binding(
      get: { navigation.presentedEpisode },
      set: { newValue in
        if newValue == nil {
          navigation.dismissEpisode()
        }
      }
    )
  }

  var resolvedItemDetailPresentation: NavigationModel.ItemDetailPresentation {
    LibraryShellPresentation.itemDetailPresentation(
      isRegularWidth: horizontalSizeClass == .regular)
  }

  /// ADR 0008: `presentedEpisodeBinding`'s shape over `NavigationModel.presentedItemDetail`.
  var presentedItemDetailBinding: Binding<NavigationModel.ItemDetailRef?> {
    Binding(
      get: { navigation.presentedItemDetail },
      set: { newValue in
        if newValue == nil {
          navigation.dismissItemDetail()
        }
      }
    )
  }

  #if PERF_INVESTIGATION
    /// Reads what the presentation chain reads, so the ablation reproduces the inline
    /// invalidation shape without a second copy of the chain.
    var inlineShellPresentationFingerprint: Int {
      var fingerprint = 0
      fingerprint &+= navigation.settingsPresentation == .presented ? 1 : 0
      fingerprint &+= navigation.presentedEpisode == nil ? 0 : 2
      fingerprint &+= navigation.presentedItemDetail == nil ? 0 : 4
      fingerprint &+= navigation.playerPresentation == .expanded ? 8 : 0
      return fingerprint
    }
  #endif

  func updateEditorialWashSuspension() {
    dependencies.paletteService.setCovered(
      isAddFeedPresented
        || EditorialSuspensionPolicy.suspended(
          settingsPresented: settingsPresentationBinding.wrappedValue,
          episodePresented: presentedEpisodeBinding.wrappedValue != nil,
          itemDetailPresented: presentedItemDetailBinding.wrappedValue != nil,
          playerPresented: playerPresentationBinding.wrappedValue)
    )
  }

  /// AppModel may not import SwiftUI, so it exposes the per-section path as a settable subscript
  /// and the binding is formed here. Writes flow straight back into the model, which makes the
  /// system back control authoritative.
  func pathBinding(for section: NavigationModel.Section) -> Binding<[NavigationModel.Route]> {
    Binding(
      get: { navigation[pathFor: section] },
      set: {
        navigation[pathFor: section] = $0
        bookZoomRegistry.reconcile(section: section, path: $0)
      }
    )
  }

  /// `RootModel` performs this same truncation at the native-subscription observation boundary.
  /// This host callback covers the brief in-flight render where the source disappears before that
  /// model update reaches SwiftUI, and preserves any earlier server destinations.
  func truncateNativeShowsDestination() {
    let path = navigation[pathFor: .podcasts]
    guard
      let index = path.firstIndex(where: { route in
        if case .nativePodcastShows = route { return true }
        return false
      })
    else { return }
    navigation[pathFor: .podcasts] = Array(path.prefix(upTo: index))
  }

  /// Item detail's one construction, shared by the pushed destination and the regular-width card
  /// (ADR 0008). The artwork-preflight teardown travels with it, so a dismissed card releases the
  /// preflight as a popped push does.
  func itemDetailDestination(
    itemID: String,
    seed: ItemSummary?,
    transitionSource: BookZoomTransitionSource? = nil
  ) -> some View {
    let detail = ItemDetailView(
      itemId: itemID, seed: seed, library: dependencies.library,
      nativePodcastShowsReading: dependencies.nativePodcastShowsReading, coverClient: dependencies.coverClient,
      paletteService: dependencies.paletteService,
      playback: playback,
      downloadReading: dependencies.downloadReading, downloadIntents: dependencies.downloadIntents,
      extrasAccess: dependencies.extrasAccess, historyAccess: dependencies.historyAccess,
      finishedStatus: finishedStatus,
      actions: actions,
      requestLocalSessionUploadDrain: dependencies.requestLocalSessionUploadDrain,
      downloadStatus: downloadStatus,
      makeAudioBookmarksModel: makeAudioBookmarksModel,
      readerReading: dependencies.readerStateReading,
      supplementReading: dependencies.supplementReading,
      connectivityModel: dependencies.connectivityModel,
      tableOfContentsReading: dependencies.readerTableOfContents,
      contentsAccess: dependencies.readerContentsAccess,
      onPresentReader: presentReader,
      onPresentReaderAtEntry: presentReader,
      onOpenMetadata: { link in
        navigation.navigate(
          to: ItemMetadataNavigationPresentation.route(for: link.destination))
      },
      effectiveAppColorScheme: effectiveAppColorScheme
    )
    .onDisappear {
      artworkPreflight.destinationDisappeared(itemID: itemID)
    }
    return detail.bookZoomTransitionDestination(transitionSource)
  }

  func select(
    _ item: ItemSummary,
    artworkRole: CoverImageView.Role,
    displaySize: CGFloat,
    podcastFilter: PodcastEpisodeFilter? = nil,
    transitionSource: BookZoomTransitionSource? = nil
  ) {
    // Capture the navigation snapshot before any asynchronous palette work. A source belongs to
    // this push; if the tab or path changes while it is prepared, the pending hand-off is
    // discarded rather than activating against whatever path is current later.
    let capturedSection = navigation.section
    let capturedPath = navigation[pathFor: capturedSection]
    let route = PodcastNavigationPresentation.route(item: item, podcastFilter: podcastFilter)
    selectionTask?.cancel()
    let transitionKey: BookZoomTransitionRegistry.Key? =
      if let transitionSource, case .itemDetail = route {
        bookZoomRegistry.prepare(
          section: capturedSection,
          path: capturedPath + [route],
          source: transitionSource)
      } else {
        nil
      }
    // Only a pending or active hand-off keeps its cover as a matched source. The membership
    // change reaches the tapped cover through the environment; the push below waits for the cover
    // to confirm it has applied the source before the route is appended.
    let pendingSource = transitionKey == nil ? nil : transitionSource
    if let pendingSource {
      activeBookZoomSources.insert(pendingSource)
    }
    let preflightSource: ArtworkSource? =
      item.providerArtworkSource
      ?? (PodcastSourceIdentity(itemId: item.serverItemId)?.rssFeedId == nil
        ? dependencies.coverClient.defaultSource
        : nil)
    let detailArtworkKey = LibraryShellPresentation.detailArtworkPreflightKey(
      for: route,
      source: preflightSource,
      displayScale: displayScale)
    artworkPreflight.start(key: detailArtworkKey) { key in
      _ = await ArtworkImagePipeline.shared.image(
        for: key, priority: .visible, client: dependencies.coverClient)
    }
    switch LibraryShellPresentation.selectionNavigationScheduling(for: item.category) {
    case .afterCurrentTransaction:
      selectionTask = Task {
        var navigated = false
        defer {
          if let transitionKey { bookZoomRegistry.dropPreparation(transitionKey) }
          if let pendingSource, navigated == false {
            activeBookZoomSources.remove(pendingSource)
          }
        }
        if let pendingSource {
          await bookZoomRelay.waitForAttachment(
            of: pendingSource, timeout: Self.bookZoomAttachmentTimeout)
        }
        await Task.yield()
        guard Task.isCancelled == false else { return }
        if let transitionKey {
          guard
            navigation.section == capturedSection,
            navigation[pathFor: capturedSection] == capturedPath
          else { return }
          bookZoomRegistry.activate(transitionKey)
        }
        navigation.navigate(to: route)
        navigated = true
        if transitionKey != nil {
          bookZoomRegistry.reconcile(
            section: capturedSection, path: navigation[pathFor: capturedSection])
        }
      }

    case .afterPalettePreparation:
      let key = CoverPaletteService.artworkKey(
        itemID: item.serverItemId,
        coverClient: dependencies.coverClient,
        displaySize: displaySize,
        displayScale: displayScale,
        role: artworkRole,
        revision: item.artworkRevision)
      selectionTask = Task {
        var navigated = false
        defer {
          if let transitionKey { bookZoomRegistry.dropPreparation(transitionKey) }
          if let pendingSource, navigated == false {
            activeBookZoomSources.remove(pendingSource)
          }
        }
        await dependencies.paletteService.prepare(
          CoverPaletteRequest(
            identity: CoverPaletteIdentity(key),
            bytes: .paletteSource(displayed: key, coverClient: dependencies.coverClient)))
        guard Task.isCancelled == false else { return }
        if let pendingSource {
          await bookZoomRelay.waitForAttachment(
            of: pendingSource, timeout: Self.bookZoomAttachmentTimeout)
          // One more turn so the attached source has been laid out before the push resolves it.
          await Task.yield()
          guard Task.isCancelled == false else { return }
        }
        if let transitionKey {
          guard
            navigation.section == capturedSection,
            navigation[pathFor: capturedSection] == capturedPath
          else { return }
          bookZoomRegistry.activate(transitionKey)
        }
        navigation.navigate(to: route)
        navigated = true
        if transitionKey != nil {
          bookZoomRegistry.reconcile(
            section: capturedSection, path: navigation[pathFor: capturedSection])
        }
      }
    }
  }

  /// Several frames at 60 Hz. A tapped cover applies its source on SwiftUI's next update, so the
  /// wait normally ends within one; the ceiling matters only if the cover is gone.
  static let bookZoomAttachmentTimeout: Duration = .milliseconds(120)

}
