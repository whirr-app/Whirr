import AppModel
import DesignSystem
import PlayerCore
import SwiftUI

/// The scrubber and its elapsed/remaining clocks. Owns the in-flight `scrubPreview` (used nowhere
/// else on the page) and reads the per-tick playhead, so only this block redraws each tick.
struct PlaybackTimelineSection: View {
  let player: any PlaybackControlling
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  let fallbackChapterMap: PlaybackChapterMap?
  let fallbackTotalDuration: Double?
  let isEnabled: Bool
  let timelineReadoutStyle: CoverAmbientPalette.TimelineReadoutStyle
  let seekFeedback: SeekFeedbackState

  @AppStorage(SkipIntervalConfiguration.forwardStorageKey)
  private var storedForwardSkipSeconds = SkipIntervalConfiguration.defaultForwardSeconds
  @AppStorage(SkipIntervalConfiguration.backwardStorageKey)
  private var storedBackwardSkipSeconds = SkipIntervalConfiguration.defaultBackwardSeconds

  /// Where the in-flight scrub currently points, `nil` when nothing is being dragged. Every
  /// time-derived readout here follows this while it is set: without it the listener drags a bar
  /// across ten hours with the clock still frozen on where they started.
  @State private var scrubPreview: ScrubPreview?
  @State private var scrubberWidth: CGFloat = 0
  @State private var bubbleSize: CGSize = .zero
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.ambientProgressFill) private var progressFill

  var body: some View {
    let state = player.state
    let liveItem = ExpandedPlayerPresentation.livePlayerItem(
      itemID: itemID, episodeID: episodeID, loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID, playerItem: state.item)
    let total = liveItem?.timeline.totalDuration ?? fallbackTotalDuration
    let chapterMap = liveItem?.chapters ?? fallbackChapterMap
    let scope = scope(chapterMap: chapterMap, totalDuration: total)
    let displayedTime = displayedGlobalTime(chapterMap: chapterMap, totalDuration: total)
    let isScrubbing = scrubPreview != nil
    let displayedFraction = PlayerTimeFormatting.scopedFraction(
      currentTime: effectivePosition, start: scope.start, end: scope.end)
    let feedbackContent = SeekFeedbackPresentation.resolved(
      scrub: scrubPreview.map { _ in displayedTime - scope.start },
      skip: seekFeedback.skipDeltaSeconds)
    let feedbackFraction = scrubPreview?.fraction ?? displayedFraction
    // `state.rate` is only this title's rate while this title is the one loaded. This section
    // also renders a retained item, and PlayerCore resets to 1x when it goes idle, so a 1.8x
    // book's own player screen would otherwise quote its remaining time at 1x.
    let effectiveRate = liveItem == nil ? playback.effectiveRate(for: itemID) : state.rate
    let chapterClocks = PlayerTimeFormatting.scopedChapterClocks(
      currentTime: displayedTime, start: scope.start, end: scope.end)

    return VStack(spacing: WhirrSpacing.xxSmall) {
      PlaybackScrubber(
        // The bar spans the current chapter, not the book: the fill and the drag both measure the
        // chapter the playhead is in. See `PlayerTimeFormatting`'s chapter-scoping note for why.
        progressFraction: displayedFraction,
        accessibilityLabel: "Playback position",
        accessibilityValue: PlayerTimeFormatting.scopedAccessibilityValue(
          currentTime: displayedTime, start: scope.start, end: scope.end, totalDuration: total,
          playbackRate: effectiveRate),
        onAdjust: { direction in
          // Routed through targeted `skip`, not a raw player seek: it prepares a session on
          // demand for a retained-but-inactive item, as the transport row does.
          let forward = direction == .increment
          let storedSeconds = forward ? storedForwardSkipSeconds : storedBackwardSkipSeconds
          let interval = Double(
            SkipIntervalConfiguration.resolvedSeconds(storedSeconds, forward: forward))
          let delta = forward ? interval : -interval
          Task { await playback.adjust(itemID: itemID, episodeID: episodeID, by: delta) }
        },
        onSeek: { fraction in
          // The scrubber reports a chapter-relative fraction; project it back to a global offset
          // before seeking, or the seek lands at that fraction of the whole book instead.
          // `startOrSeek` prepares a session on demand when this item isn't active yet.
          let offset = PlayerTimeFormatting.scopedTime(fraction: fraction, start: scope.start, end: scope.end)
          Task {
            await playback.startOrSeek(
              itemID: itemID, toGlobalOffset: offset, episodeID: episodeID)
          }
        },
        onScrub: { preview in
          if preview != nil, scrubPreview == nil {
            seekFeedback.cancelSkipEpisode()
          }
          scrubPreview = preview
        },
        fillColor: progressFill
      )
      .disabled(isEnabled == false)
      .accessibilityIdentifier(PlayerAccessibilityID.expandedScrubber)
      .onGeometryChange(for: CGFloat.self) {
        $0.size.width
      } action: {
        scrubberWidth = $0
      }
      .overlay(alignment: .topLeading) {
        if let feedbackContent {
          let text: String =
            switch feedbackContent {
            case .scrub(let targetSeconds):
              SeekFeedbackPresentation.scrubLabel(targetSeconds: targetSeconds)
            case .skip(let deltaSeconds):
              SeekFeedbackPresentation.skipLabel(deltaSeconds: deltaSeconds)
            }

          SeekFeedbackBubble(text: text)
            .onGeometryChange(for: CGSize.self) {
              $0.size
            } action: {
              bubbleSize = $0
            }
            .offset(
              x: SeekFeedbackPresentation.bubbleCenter(
                trackWidth: scrubberWidth, bubbleWidth: bubbleSize.width, fraction: feedbackFraction),
              y: (PlayerMetric.scrubberHitTargetHeight
                - (isScrubbing ? PlayerMetric.scrubberActiveTrackHeight : PlayerMetric.scrubberVisualTrackHeight))
                / 2 - bubbleSize.height - PlayerMetric.seekFeedbackTrackGap
            )
            .transition(
              .opacity.combined(with: reduceMotion ? .identity : .scale(scale: 0.9)))
        }
      }
      .animation(
        PlayerMotion.seekFeedbackAnimation(reduceMotion: reduceMotion),
        value: feedbackContent != nil)

      ZStack {
        HStack {
          Text(chapterClocks.elapsed)
          Spacer()
          Text(chapterClocks.remaining)
        }

        // Centred under the bar: the precision label while a scrub is in flight, otherwise the
        // overall time left in the whole book, which chapter scoping would otherwise hide.
        // Shown only when a chapter narrows the scope, so a chapterless book (whose bar already
        // spans the book) never renders the same remainder twice.
        VStack(spacing: 1) {
          if let precisionLabel = scrubPreview.flatMap({ ExpandedPlayerView.precisionLabel($0.speed) }) {
            Text(precisionLabel)
              .transition(
                .opacity.animation(PlayerMotion.timelineReadoutAnimation(reduceMotion: reduceMotion)))
          } else if scope.isChapter,
            let bookRemaining = PlayerTimeFormatting.bookRemainingLabel(
              currentTime: displayedTime, totalDuration: total,
              playbackRate: effectiveRate, isEpisode: episodeID != nil)
          {
            Text(bookRemaining)
              .transition(
                .opacity.animation(PlayerMotion.timelineReadoutAnimation(reduceMotion: reduceMotion)))
          }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(timelineReadoutStyle.ink.opacity(timelineReadoutStyle.centeredOpacity))
      }
      .font(.caption.monospacedDigit().weight(.medium))
      .foregroundStyle(
        timelineReadoutStyle.ink.opacity(
          isScrubbing
            ? timelineReadoutStyle.scrubbingOpacity : timelineReadoutStyle.regularOpacity)
      )
      .animation(
        PlayerMotion.timelineScrubbingAnimation(reduceMotion: reduceMotion), value: isScrubbing
      )
      .accessibilityHidden(true)
    }
  }

  /// The chapter window the scrubber spans: the chapter that owns the live or metadata-backed
  /// playhead, falling back to the whole book for a chapterless book or a position in a gap.
  /// Resolved at the live playhead (not the scrub preview) so an in-flight drag, which stays
  /// inside this window, can never re-scope the bar out from under itself.
  private func scope(chapterMap: PlaybackChapterMap?, totalDuration: Double?) -> PlaybackScope {
    let total = totalDuration ?? 0
    guard let chapter = chapterMap?.currentChapter(at: effectivePosition) else {
      return PlaybackScope(start: 0, end: total, isChapter: false)
    }
    return PlaybackScope(start: chapter.start, end: chapter.end, isChapter: true)
  }

  /// The global time every readout on the page should show: where the finger points while a scrub
  /// is in flight (the chapter-relative preview fraction projected back onto the chapter window),
  /// otherwise the displayed playhead (`effectivePosition`).
  private func displayedGlobalTime(
    chapterMap: PlaybackChapterMap?, totalDuration: Double?
  ) -> Double {
    guard let fraction = scrubPreview?.fraction else { return effectivePosition }
    let scope = scope(chapterMap: chapterMap, totalDuration: totalDuration)
    return PlayerTimeFormatting.scopedTime(fraction: fraction, start: scope.start, end: scope.end)
  }

  /// The live playhead once a session for this item exists, otherwise the retained projection's
  /// saved position (`PlaybackModel.displayedPositionSeconds`), never the stale
  /// `playback.currentTime` left over from whichever item was last active. A finished retained
  /// item reads as played to its end.
  private var effectivePosition: Double {
    ExpandedPlayerPresentation.timelinePositionSeconds(
      itemID: itemID, episodeID: episodeID,
      savedPosition: playback.displayedPositionSeconds(
        itemID: itemID, episodeID: episodeID, persisted: 0),
      displayedItem: playback.displayedItem,
      isLoaded: playback.loadedItemID == itemID && playback.loadedEpisodeID == episodeID,
      totalDuration: fallbackTotalDuration)
  }
}

/// The sub-window of the book timeline the scrubber spans. `isChapter` distinguishes a genuine
/// chapter narrowing (draw the book-remaining label; the bar means the chapter) from the whole-book
/// fallback used for a chapterless book or a gap between chapters (where a book-remaining label
/// would only repeat the right-hand remainder).
private struct PlaybackScope {
  let start: Double
  let end: Double
  let isChapter: Bool
}
