import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

/// The persistent, global mini-player (see ARCHITECTURE.md): hosted in `LibraryShellView`'s
/// `.tabViewBottomAccessory`, so it survives every tab/section change. Pure state-over-
/// `PlaybackModel`/`PlaybackControlling` binding, with no playback decision-making here.
struct MiniPlayerContainerView: View {
  let playback: PlaybackModel
  let connectivityModel: ConnectivityModel?
  let player: any PlaybackControlling
  let library: any LibraryReading
  let nativePodcastShowsReading: any NativePodcastShowsReading
  let coverClient: any ArtworkServing
  /// Opens the expanded player, seeded with what this bar already knows about the item. See
  /// `expandSeed`.
  let onExpand: (PlayerMetadataSeed?) -> Void
  /// Captured by `LibraryShellView` before `tabViewBottomAccessory` moves this view into its
  /// system-owned vibrancy host. See `MiniPlayerView.contentColorScheme`.
  let contentColorScheme: ColorScheme
  /// The account's palette service, shared with `ExpandedPlayerView` so both surfaces theme from
  /// one derivation per cover, and the expanded player opens on this one's answer.
  let paletteService: CoverPaletteService
  /// Shell-lifetime RSS artwork identity. Optional for standalone/test compositions that do not
  /// mount the Library shell; production always supplies the shell's resolver.
  var followedShowArtworkSources: FollowedShowArtworkSources? = nil
  /// The shell's observation of the playing episode's own image. Nil in compositions without one.
  var episodeArtwork: PlayerEpisodeArtwork? = nil
  /// The expanded player's identity-matched queue seed, if one is available during the queue
  /// transition. `ExpandedPlayerPresentation.metadata` discards it for any other live identity.
  var metadataSeed: PlayerMetadataSeed? = nil
  /// The one owner of playback speed, for the regular-width speed control. Optional for the same
  /// standalone compositions as above; without it the bar shows no speed control.
  var playbackRate: PlaybackRateCoordinator? = nil

  @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
  @Environment(\.displayScale) private var displayScale
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  /// Not `@AppStorage`: that invalidates on any `UserDefaults` write, and this view is hosted as
  /// persistent chrome on every screen. See `SkipIntervalStore`.
  private let skipIntervals = SkipIntervalStore.shared
  @State private var itemModel: ItemDetailModel?
  /// Written by `MiniPlayerChapterTitleReader` once per chapter change, never per playhead tick.
  @State private var chapterTitle: String?
  /// An ad-skip receipt, shown in place of the subtitle while it lasts.
  @State private var adSkipReceipt: PlaybackSkipReceipt?
  /// The width the accessory gives the bar. The system owns it and it does not depend on what the
  /// bar shows, so measuring it cannot feed back into itself.
  @State private var barWidth: CGFloat?
  /// What the bar's cover last drew, for the open morph's cover flight. A reference the view does
  /// not observe, so the cover recording a draw never re-evaluates this body.
  @State private var drawnBarCover = DrawnArtwork()
  /// The expanded page's cover, prepared while the bar shows this item so the open morph's cover
  /// flight is sharp from its first frame. Held here, not only in the prepared cache, which
  /// empties when the app is backgrounded.
  @State private var warmedPageCover = DrawnArtwork()

  private struct ArtworkTaskID: Hashable {
    let itemID: String
    let source: ArtworkSource?
    let revision: ArtworkRevision
    /// Until the item loads, its source and revision are placeholders (`CoverPaletteIdentity`).
    let isProvisional: Bool
  }

  /// The live session when there is one, otherwise the retained "last played" item.
  /// Mirrors `MiniPlayerAccessoryPresentation.isPresented`, the predicate `LibraryShellView` uses
  /// to decide whether to attach the accessory this view is hosted in at all, so the two can never
  /// disagree about whether there's something to show.
  private var displayedItemID: String? {
    MiniPlayerAccessoryPresentation.displayedItemID(
      nowPlayingIdentity: playback.nowPlayingIdentity)
  }

  private var displayedEpisodeID: String? {
    MiniPlayerAccessoryPresentation.displayedEpisodeID(
      activeItemID: playback.activeItemID, activeEpisodeID: playback.activeEpisodeID,
      displayedItem: playback.displayedItem)
  }

  private func isTransportEnabled(for itemID: String) -> Bool {
    ExpandedPlayerPresentation.isTransportEnabled(
      itemID: itemID, episodeID: displayedEpisodeID, activeItemID: playback.activeItemID,
      activeEpisodeID: playback.activeEpisodeID, loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID, displayedItem: playback.displayedItem)
  }

  var body: some View {
    if let itemID = displayedItemID {
      let resolution = artworkResolution(itemID: itemID)
      let artworkSource = resolution.source
      let artworkRevision = loadedItem?.artworkRevision ?? .unversioned
      bar(
        itemID: itemID, isTitleMarqueeActive: MiniPlayerAccessoryPresentation.isTitleMarqueeEnabled
      ) {
        CoverImageView(
          itemID: itemID, title: title, displaySize: PlayerMetric.miniPlayerCoverSize,
          client: coverClient, source: artworkSource,
          fallbackSource: resolution.fallbackSource, revision: artworkRevision,
          drawnArtwork: drawnBarCover
        )
        .playerMorphAnchor(
          .barCover, drawnCover: drawnBarCover, warmedPageCover: warmedPageCover
        ) {
          CoverImageView.artworkKey(
            itemID: itemID, client: coverClient, source: artworkSource,
            displaySize: PlayerMetric.miniPlayerCoverSize, displayScale: displayScale,
            role: .libraryThumbnail, revision: artworkRevision)
        }
        .playerMorphHidesDuringCoverFlight()
      }
      // The same bar with nothing in the cover's slot and a title at rest: what a collapse into
      // this bar carries on its panel until the bar itself is shown again.
      .playerMorphBarLabel(bar(itemID: itemID, isTitleMarqueeActive: false) { Color.clear })
      .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { barWidth = $0 }
      .accessibilityIdentifier(PlayerAccessibilityID.miniPlayerContainer)
      .accessibilityActions {
        if let receipt = adSkipReceipt, receipt.canUndo {
          Button(AdSkipReceiptPresentation.undoActionName) {
            adSkipReceipt = nil
            playback.undoLastSkip()
          }
        }
      }
      .tracksAdSkipReceipt(playback, visible: $adSkipReceipt, staysForVoiceOver: false)
      .background {
        if readsChapterTitle {
          MiniPlayerChapterTitleReader(
            player: player, playback: playback, itemID: itemID, chapterTitle: $chapterTitle)
        }
      }
      .tracksEpisodeArtwork(episodeArtwork, itemID: itemID, episodeID: displayedEpisodeID)
      .task(id: itemID) {
        // Protects the active item's palette from bounded eviction, through its identity changes.
        paletteService.pin(itemID: itemID)
        harnessNote(.miniPlayerModelTask)
        itemModel = ItemDetailModel(
          itemId: itemID, library: library, nativePodcastShowsReading: nativePodcastShowsReading)
      }
      // Keyed on the resolved source too: a followed show whose source lands after the first
      // frame (cold launch) re-derives under its real key without rebuilding the models above;
      // the owner's `sourceChanged` has already cleared the placeholder key's leftovers. The
      // revision likewise arrives with the loaded summary; until then the identity is
      // provisional: it may show a saved row but never saves one over the resolved row.
      .task(
        id: ArtworkTaskID(
          itemID: itemID, source: artworkSource, revision: artworkRevision,
          isProvisional: loadedItem == nil)
      ) {
        let key = CoverPaletteService.artworkKey(
          itemID: itemID, coverClient: coverClient,
          source: artworkSource,
          displaySize: PlayerMetric.miniPlayerCoverSize, displayScale: displayScale,
          role: .libraryThumbnail, revision: artworkRevision)
        let identity = resolution.paletteIdentity(for: key, isProvisional: loadedItem == nil)
        await paletteService.show(
          identity,
          bytes: .paletteSource(
            displayed: key, coverClient: coverClient))
        await paletteService.waitForPalette(identity)
      }
      // The same identity as the palette's task: the page keys its cover by the loaded item's
      // source and revision (`expandSeed`), so a provisional key would warm a cover it never asks
      // for.
      .task(
        id: ArtworkTaskID(
          itemID: itemID, source: artworkSource, revision: artworkRevision,
          isProvisional: loadedItem == nil)
      ) {
        guard loadedItem != nil else { return }
        let key = CoverImageView.artworkKey(
          itemID: itemID, client: coverClient, source: artworkSource,
          displaySize: ExpandedPlayerView.artworkRequestSize, displayScale: displayScale,
          role: .highFidelity, revision: artworkRevision)
        guard
          let image = await ArtworkImagePipeline.shared.image(
            for: key, priority: .visible, client: coverClient),
          Task.isCancelled == false
        else { return }
        warmedPageCover.note(image, for: key)
      }
    }
  }

  private var showsRegularWidthControls: Bool {
    MiniPlayerAccessoryPresentation.showsRegularWidthControls(
      for: horizontalSizeClass, barWidth: barWidth)
  }

  private var readsChapterTitle: Bool {
    showsRegularWidthControls && displayedEpisodeID == nil
  }

  /// The bar for `itemID` around `cover`. Built twice per body: once as the bar, and once with an
  /// empty cover slot as the label a collapse carries (`playerMorphBarLabel`), so the two cannot
  /// drift apart.
  private func bar<Cover: View>(
    itemID: String, isTitleMarqueeActive: Bool, @ViewBuilder cover: () -> Cover
  ) -> some View {
    let quickActionsItem = player.quickActions.item
    let liveDuration = ExpandedPlayerPresentation.liveQuickActionsItem(
      itemID: itemID, episodeID: displayedEpisodeID, loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID, quickActionsItem: quickActionsItem
    )?.totalDuration
    let transportEnabled = isTransportEnabled(for: itemID)
    let forwardSkipSeconds = skipIntervals.forwardSeconds
    let backwardSkipSeconds = skipIntervals.backwardSeconds
    let status = miniPlayerStatus(chapterTitle: readsChapterTitle ? chapterTitle : nil)
    let playingHere = playback.isPlaybackIntended(for: itemID)
    let onWatch = CompanionDeviceIndicatorPresentation.shows(
      watchPlaying: playback.isPlayingOnCompanion(itemID: itemID, episodeID: displayedEpisodeID),
      playingHere: playingHere)
    return MiniPlayerView(
      title: title,
      subtitle: adSkipReceipt.map(AdSkipReceiptPresentation.text(for:))
        ?? (onWatch ? CompanionDeviceIndicatorPresentation.text : status.subtitle),
      subtitleSystemImage: adSkipReceipt != nil
        ? "forward.end" : onWatch ? CompanionDeviceIndicatorPresentation.systemImage : status.systemImage,
      isPlaying: playingHere,
      playPauseAccessibilityLabel: playingHere
        ? "Pause" : onWatch ? CompanionDeviceIndicatorPresentation.takeOverLabel : "Play",
      skipBackAccessibilityLabel: SkipIntervalConfiguration.accessibilityLabel(
        seconds: backwardSkipSeconds, forward: false),
      skipBackAccessibilityHint: SkipIntervalConfiguration.accessibilityHint(
        seconds: backwardSkipSeconds, forward: false),
      skipBackSystemImage: SkipIntervalConfiguration.systemImage(
        seconds: backwardSkipSeconds, forward: false),
      skipForwardAccessibilityLabel: SkipIntervalConfiguration.accessibilityLabel(
        seconds: forwardSkipSeconds, forward: true),
      skipForwardAccessibilityHint: SkipIntervalConfiguration.accessibilityHint(
        seconds: forwardSkipSeconds, forward: true),
      skipForwardSystemImage: SkipIntervalConfiguration.systemImage(
        seconds: forwardSkipSeconds, forward: true),
      progressAccessibilityValue: {
        let displayedPosition = playback.displayedPositionSeconds(
          itemID: itemID, episodeID: displayedEpisodeID, persisted: 0)
        return PlayerTimeFormatting.elapsedOfTotal(
          currentTime: displayedPosition, duration: liveDuration)
      },
      expandAccessibilityHint: "Opens the full player.",
      coverAccessibilityLabel: nil,
      layout: MiniPlayerAccessoryPresentation.layout(for: accessoryPlacement),
      contentMaxWidth: MiniPlayerAccessoryPresentation.contentMaxWidth(
        for: horizontalSizeClass),
      isTitleMarqueeActive: isTitleMarqueeActive,
      contentColorScheme: contentColorScheme,
      isTransportEnabled: transportEnabled,
      cover: cover,
      accessory: {
        if showsRegularWidthControls, let playbackRate {
          MiniPlayerRegularWidthControls(
            player: player, playback: playback, playbackRate: playbackRate, itemID: itemID,
            episodeID: displayedEpisodeID)
        }
      },
      onPlayPauseTap: {
        PlayerTransportIntents(
          playback: playback, itemID: itemID, episodeID: displayedEpisodeID
        ).toggle()
      },
      onSkipBackTap: {
        PlayerTransportIntents(
          playback: playback, itemID: itemID, episodeID: displayedEpisodeID
        ).skip(by: -Double(backwardSkipSeconds))
      },
      onSkipForwardTap: {
        PlayerTransportIntents(
          playback: playback, itemID: itemID, episodeID: displayedEpisodeID
        ).skip(by: Double(forwardSkipSeconds))
      },
      onExpandTap: { onExpand(expandSeed) }
    )
  }

  private var title: String {
    metadata.title
  }

  private func miniPlayerStatus(chapterTitle: String?)
    -> ExpandedPlayerPresentation.MiniPlayerStatus
  {
    ExpandedPlayerPresentation.miniPlayerStatus(
      author: metadata.author,
      phase: playback.phase,
      isStreamingSource: playback.isStreamingSource,
      reachability: connectivityModel?.reachability ?? .unknown,
      itemID: playback.loadedItemID,
      startFailureMessage: playback.startFailureMessage,
      chapterTitle: chapterTitle)
  }

  private var metadata: ExpandedPlayerPresentation.DisplayedMetadata {
    ExpandedPlayerPresentation.metadata(
      itemID: displayedItemID ?? "", episodeID: displayedEpisodeID,
      displayedItem: playback.displayedItem, liveTitle: loadedItem?.title,
      liveAuthor: loadedItem?.author, metadataSeed: metadataSeed)
  }

  /// What the bar already shows, for the page's first frame: above all the cover's revision. The
  /// page's own item loads only after it appears, so without this it keys its cover `unversioned`
  /// and the open's cover flight cannot match the bar's. Only once this bar's item has loaded, so
  /// the seed never carries a placeholder title.
  private var expandSeed: PlayerMetadataSeed? {
    guard let identity = playback.nowPlayingIdentity, let loadedItem else { return nil }
    let metadata = metadata
    return PlayerMetadataSeed(
      identity: identity, title: metadata.title, author: metadata.author,
      artworkSource: loadedItem.providerArtworkSource, artworkRevision: loadedItem.artworkRevision,
      episodeArtworkSource: artworkResolution(itemID: identity.itemID).episodeSource)
  }

  /// The same resolution the page computes (`ExpandedPlayerView.artworkResolution`), so the open
  /// flight's covers match.
  private func artworkResolution(itemID: String) -> PlayerArtworkResolution {
    .resolve(
      itemID: itemID, episodeID: displayedEpisodeID,
      followedShowSource: followedShowArtworkSources?.source(for: itemID),
      loadedSource: loadedItem?.providerArtworkSource, seed: metadataSeed,
      episodeArtwork: episodeArtwork)
  }

  private var loadedItem: ItemSummary? {
    guard case .loaded(let item) = itemModel?.state, item.serverItemId == displayedItemID else {
      return nil
    }
    return item
  }

}
