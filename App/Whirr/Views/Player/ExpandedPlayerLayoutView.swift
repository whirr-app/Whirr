import ABSApi
import AppModel
import DesignSystem
import PlayerCore
import SwiftUI

/// The expanded player's geometry-only composition. State and presentation decisions remain owned by
/// `ExpandedPlayerView`; this view receives the resolved metadata, palette values, bindings, and
/// interaction closures it needs to render the stacked or side-by-side composition.
struct ExpandedPlayerLayoutView<DismissHandle: View, KeyboardShortcuts: View, InlineQueue: View>:
  View
{
  let widthClass: ExpandedPlayerLayoutPresentation.WidthClass
  /// A compact vertical size class: an iPhone in landscape, where the cover goes beside the
  /// details rather than above them.
  var isCompactHeight = false
  let itemID: String
  let episodeID: String?
  let title: String
  let author: String?
  let playback: PlaybackModel
  let connectivityModel: ConnectivityModel?
  let player: any PlaybackControlling
  let coverClient: any ArtworkServing
  let artworkSource: ArtworkSource?
  /// The show's cover, drawn when the episode's own image cannot be had.
  var artworkFallbackSource: ArtworkSource? = nil
  let artworkRevision: ArtworkRevision
  let metadataChapterMap: PlaybackChapterMap?
  let isTransportEnabled: Bool
  let bylineDestination: PlayerBylineNavigationPresentation.Destination?
  let onSelectByline: () -> Void
  let actions: ItemActionsModel
  let itemDetailDuration: Double?
  let onShowHistory: () -> Void
  let supplementCount: Int
  let onShowSupplements: () -> Void
  let onAddBookmark: () -> Void
  let onViewDetails: () -> Void
  /// Raises the page's transcript sheet; nil hides the overflow entry.
  var onShowTranscript: (() -> Void)? = nil
  /// Raises Look Back; the metadata section decides whether the book offers it.
  var onShowLookBack: (() -> Void)? = nil
  @Binding var isShowingChapters: Bool
  let fallbackTotalDuration: Double?
  let timelineReadoutStyle: CoverAmbientPalette.TimelineReadoutStyle
  let seekFeedback: SeekFeedbackState
  let playPauseFill: Color
  let playbackRate: PlaybackRateCoordinator
  @Binding var isShowingSleepTimer: Bool
  @Binding var isShowingUpNext: Bool
  /// The stacked compact page's queue mode: the cover and title shrink into a header and
  /// `inlineQueue` takes the rest of the upper region (`InlineUpNextPresentation`).
  var isShowingInlineQueue = false
  let inlineQueue: InlineQueue?
  let loadedItemID: String?
  let loadedEpisodeID: String?
  let pageBackground: Color
  /// `AmbientCanvasLatch.adoptionGeneration`, forwarded to the canvas so a late palette crossfades
  /// while an already-derived one lands on the first frame of the item change.
  var pageBackgroundAdoptionGeneration: Int = 0
  let artworkInk: Color
  let dismissHandle: DismissHandle
  let keyboardShortcuts: KeyboardShortcuts
  let isAccessibilitySize: Bool
  @Binding var upperContentHeight: CGFloat
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The cover's flight into the header and back. Reduce Motion swaps the modes without travel.
  private var queueModeAnimation: Animation? {
    reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)
  }

  var body: some View {
    ZStack {
      PlayerAmbientBackground(
        background: pageBackground, adoptionGeneration: pageBackgroundAdoptionGeneration)

      GeometryReader { pageProxy in
        let plan = ExpandedPlayerLayoutPresentation.resolve(
          widthClass: widthClass,
          isCompactHeight: isCompactHeight,
          pageWidth: pageProxy.size.width,
          pageHeight: pageProxy.size.height,
          upperRegionHeight: pageProxy.size.height,
          measuredMetadataHeight: upperContentHeight,
          isAccessibilitySize: isAccessibilitySize)

        switch plan {
        case .compactStacked(let stackedPlan), .regularStacked(let stackedPlan):
          stackedPage(pageProxy: pageProxy, initialPlan: stackedPlan)
        case .sideBySide(let sideBySidePlan):
          sideBySidePage(pageProxy: pageProxy, initialPlan: sideBySidePlan)
        }
      }
      // The page takes the bottom inset back and the chrome sets its own clearance from the edge
      // it then has. Only this edge: the top inset, the dismiss handle, and the upper region are
      // untouched, and `.container` leaves the keyboard's own inset alone.
      .ignoresSafeArea(
        .container,
        edges: ExpandedPlayerView.ignoredContainerEdges(isAccessibilitySize: isAccessibilitySize))
    }
  }

  /// The compact-height and short-page composition. The cover stays outside the page's one scroll view, which
  /// holds only the metadata and status; the chrome is that scroll view's intrinsic sibling at the
  /// foot of the right column, as it is at the foot of the stacked page. Dismissal discovers the
  /// scroll view the same way in either composition.
  private func sideBySidePage(
    pageProxy: GeometryProxy,
    initialPlan: ExpandedPlayerLayoutPresentation.SideBySidePlan
  ) -> some View {
    VStack(spacing: 0) {
      dismissHandle

      GeometryReader { regionProxy in
        let plan =
          ExpandedPlayerLayoutPresentation.resolve(
            widthClass: widthClass,
            isCompactHeight: isCompactHeight,
            pageWidth: pageProxy.size.width,
            pageHeight: pageProxy.size.height,
            upperRegionHeight: regionProxy.size.height,
            measuredMetadataHeight: upperContentHeight,
            isAccessibilitySize: isAccessibilitySize
          ).sideBySidePlan ?? initialPlan

        HStack(spacing: plan.columnSpacing) {
          ExpandedPlayerArtwork(
            itemID: itemID,
            title: title,
            coverSize: plan.artworkSize,
            coverClient: coverClient,
            source: artworkSource,
            fallbackSource: artworkFallbackSource,
            revision: artworkRevision,
            playback: playback,
            ink: artworkInk
          )
          .playerLayoutProbed(.cover)

          VStack(spacing: 0) {
            // Bottom-aligned within the scroll view's own height so the title sits just above
            // the scrubber, and scrolls from the top when accessibility sizes overflow it.
            GeometryReader { detailProxy in
              playerPageScrollView {
                VStack(spacing: 0) {
                  metadataAndStatus
                  keyboardShortcuts
                }
                .frame(
                  maxWidth: .infinity, minHeight: detailProxy.size.height, alignment: .bottom)
              }
            }

            playerChrome
              .padding(.top, WhirrSpacing.medium)
              .padding(.bottom, PlayerMetric.chromeBottomClearance)
          }
          .frame(width: plan.detailColumnWidth)
        }
        .padding(.horizontal, plan.horizontalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  /// Compact and regular widths share this renderer. The regular plan gives its larger artwork
  /// cluster equal slack above and below the measured upper band.
  private func stackedPage(
    pageProxy: GeometryProxy,
    initialPlan: ExpandedPlayerLayoutPresentation.StackedPlan
  ) -> some View {
    VStack(spacing: 0) {
      dismissHandle

      // The upper region stays flexible; the intrinsic chrome below it is what fixes the lower
      // controls at the page bottom.
      GeometryReader { upperProxy in
        let measuredPlan = ExpandedPlayerLayoutPresentation.resolve(
          widthClass: widthClass,
          pageWidth: pageProxy.size.width,
          upperRegionHeight: upperProxy.size.height,
          measuredMetadataHeight: upperContentHeight,
          isAccessibilitySize: isAccessibilitySize)
        let plan = measuredPlan.stackedPlan ?? initialPlan
        let header = InlineUpNextPresentation.header

        VStack(spacing: 0) {
          stackedScrollView(
            plan: plan,
            upperRegionHeight: isShowingInlineQueue ? header.height : upperProxy.size.height
          )
          .frame(height: isShowingInlineQueue ? header.height : upperProxy.size.height)

          if isShowingInlineQueue, let inlineQueue {
            inlineQueue
              .mask { queueBottomFade }
              .transition(.opacity)
          }
        }
        .animation(queueModeAnimation, value: isShowingInlineQueue)
      }

      playerChrome
        .padding(.horizontal, initialPlan.horizontalPadding)
        .padding(.bottom, PlayerMetric.chromeBottomClearance)
    }
  }

  private func stackedScrollView(
    plan: ExpandedPlayerLayoutPresentation.StackedPlan,
    upperRegionHeight: CGFloat
  ) -> some View {
    let header = InlineUpNextPresentation.header
    // One cover in one container for both modes, so it keeps its identity and animates between
    // the page's subject and the queue header's thumbnail.
    let arrangement =
      isShowingInlineQueue
      ? AnyLayout(HStackLayout(alignment: .center, spacing: header.artworkToTitleSpacing))
      : AnyLayout(VStackLayout(spacing: 0))

    return playerPageScrollView(isInlineQueueHeader: isShowingInlineQueue) {
      VStack(spacing: 0) {
        arrangement {
          ExpandedPlayerArtwork(
            itemID: itemID,
            title: title,
            coverSize: isShowingInlineQueue ? header.artworkSize : plan.artworkSize,
            coverClient: coverClient,
            source: artworkSource,
            fallbackSource: artworkFallbackSource,
            revision: artworkRevision,
            playback: playback,
            ink: artworkInk
          )
          .playerLayoutProbed(.cover)

          if isShowingInlineQueue {
            queueHeaderTitle
              .transition(.opacity)
          } else {
            metadataAndStatus
              .padding(.top, plan.artworkToMetadataSpacing)
              .transition(.opacity)
          }
        }

        keyboardShortcuts
      }
      .padding(.top, isShowingInlineQueue ? header.verticalPadding : plan.upperSlackAbove)
      .padding(.bottom, isShowingInlineQueue ? header.verticalPadding : plan.upperSlackBelow)
      .padding(.horizontal, plan.horizontalPadding)
      .frame(maxWidth: .infinity, minHeight: upperRegionHeight, alignment: .top)
    }
  }

  /// What is playing, beside the header thumbnail. Identity only: the chapter row, overflow and
  /// status banner return with the full page.
  private var queueHeaderTitle: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      Text(title)
        .font(WhirrTypeToken.headline.font)
        .lineLimit(2)
      if let author {
        Text(author)
          .font(WhirrTypeToken.subheadline.font)
          .foregroundStyle(WhirrMetadataProminence.playerByline.adaptiveStyle)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  /// Opaque above, fading out over the last rows so the queue dissolves above the scrubber.
  private var queueBottomFade: some View {
    VStack(spacing: 0) {
      Color.black
      LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
        .frame(height: InlineUpNextPresentation.queueBottomFadeHeight)
    }
  }

  /// The one page scroll view owns the complete stacked upper composition, including artwork. The
  /// chrome remains its intrinsic sibling below this view so dismissal can discover this boundary.
  private func playerPageScrollView<Content: View>(
    isInlineQueueHeader: Bool = false,
    @ViewBuilder content: () -> Content
  ) -> some View {
    PlayerPageScrollView(content: content(), isInlineQueueHeader: isInlineQueueHeader)
  }

  /// Metadata and status are the only measured upper-content variance. They stay in the page's
  /// scroll content while the chrome remains a sibling and therefore keeps its bottom coordinate.
  private var metadataAndStatus: some View {
    VStack(spacing: 0) {
      ListeningMetadataSection(
        player: player,
        playback: playback,
        itemID: itemID,
        episodeID: episodeID,
        title: title,
        author: author,
        fallbackChapterMap: metadataChapterMap,
        isTransportEnabled: isTransportEnabled,
        bylineDestination: bylineDestination,
        onSelectByline: onSelectByline,
        actions: actions,
        itemDetailDuration: itemDetailDuration,
        onShowHistory: onShowHistory,
        supplementCount: supplementCount,
        onShowSupplements: onShowSupplements,
        onViewDetails: onViewDetails,
        onAddBookmark: onAddBookmark,
        onShowTranscript: onShowTranscript,
        onShowLookBack: onShowLookBack,
        isShowingChapters: $isShowingChapters
      )
      .playerLayoutProbed(.metadata)

      // In the layout flow, not floating: the banner's own conditional padding is included only
      // when it draws, so idle players are not charged for a banner they do not show.
      StatusBannerSection(playback: playback, connectivityModel: connectivityModel)
    }
    .onGeometryChange(for: CGFloat.self) {
      $0.size.height
    } action: {
      upperContentHeight = $0
    }
  }

  private var playerChrome: some View {
    PlayerChromeRegion(
      player: player,
      playback: playback,
      itemID: itemID,
      episodeID: episodeID,
      fallbackChapterMap: metadataChapterMap,
      fallbackTotalDuration: fallbackTotalDuration,
      isEnabled: isTransportEnabled,
      timelineReadoutStyle: timelineReadoutStyle,
      seekFeedback: seekFeedback,
      playPauseFill: playPauseFill,
      playbackRate: playbackRate,
      isShowingSleepTimer: $isShowingSleepTimer,
      isShowingUpNext: $isShowingUpNext,
      loadedItemID: loadedItemID,
      loadedEpisodeID: loadedEpisodeID
    )
    // Floats over the metadata rather than joining the layout, so the cover never resizes for it.
    .modifier(AdSkipReceiptOverlay(playback: playback))
  }
}

/// The page's scroll view. A view of its own so the overflow state it tracks invalidates only this
/// container, not the layout above it.
private struct PlayerPageScrollView<Content: View>: View {
  let content: Content
  /// The stacked page in Up Next mode, where the scroll view is the fixed-height queue header.
  var isInlineQueueHeader = false
  @State private var clipsContent = false

  var body: some View {
    ScrollView {
      content
    }
    .scrollIndicators(.hidden)
    .scrollBounceBehavior(.basedOnSize, axes: .vertical)
    .scrollClipDisabled(!clipsContent)
    .onScrollGeometryChange(for: Bool.self) { [isInlineQueueHeader] geometry in
      ExpandedPlayerLayoutPresentation.pageScrollClipsContent(
        contentHeight: geometry.contentSize.height,
        containerHeight: geometry.containerSize.height,
        isInlineQueueHeader: isInlineQueueHeader)
    } action: { _, clips in
      clipsContent = clips
    }
  }
}
