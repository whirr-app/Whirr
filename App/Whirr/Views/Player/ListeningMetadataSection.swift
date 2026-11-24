import AppModel
import DesignSystem
import PlayerCore
import SwiftUI

/// The chapter row's label font, shared by the row and the probe that measures it. They must match
/// or the measurement describes a different string than the one drawn.
private let chapterFont: Font = .subheadline.weight(.semibold)

/// Title to byline spacing, shared by the block and by the probe that measures it with a full
/// budget's worth of title. A different spacing in the probe reserves a different height than the
/// one on screen.
private let titleBylineSpacing: CGFloat = 5

/// Chapter heading + title/author, resolved at the live playhead. Isolated into its own view so
/// the per-tick `currentTime` read redraws only this block, not the whole page.
struct ListeningMetadataSection: View {
  let player: any PlaybackControlling
  let playback: PlaybackModel
  let itemID: String
  let episodeID: String?
  let title: String
  let author: String?
  let fallbackChapterMap: PlaybackChapterMap?
  /// Chapter jumps share the transport availability gate even though they draw beside the chapter
  /// label. The selector itself is available whenever chapter metadata exists.
  let isTransportEnabled: Bool
  let bylineDestination: PlayerBylineNavigationPresentation.Destination?
  let onSelectByline: () -> Void
  /// The overflow bubble's menu contents. Resolved here rather than by the page because the live
  /// item this block already reads is one of the two sources the finish duration falls back
  /// through. The other is the item-detail projection below.
  let actions: ItemActionsModel
  let itemDetailDuration: Double?
  /// Raises the page's listening-history sheet from the overflow menu.
  let onShowHistory: () -> Void
  /// The playing book's companion PDFs, raised from the overflow menu.
  let supplementCount: Int
  let onShowSupplements: () -> Void
  /// Leaves for the item's detail surface from the overflow menu.
  let onViewDetails: () -> Void
  /// Saves a bookmark at the playhead, offered only while this audiobook is the loaded one.
  let onAddBookmark: () -> Void
  /// Raises the page's transcript sheet; nil while the loaded episode has no transcript to offer.
  var onShowTranscript: (() -> Void)? = nil
  /// Raises Look Back; offered here only while this audiobook is the loaded one.
  var onShowLookBack: (() -> Void)? = nil
  @Binding var isShowingChapters: Bool
  var body: some View {
    let liveItem = ExpandedPlayerPresentation.livePlayerItem(
      itemID: itemID, episodeID: episodeID, loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID, playerItem: player.state.item)
    // `chapterMap` falls back to the item-detail projection until a live session exists, so a
    // missing map is the unresolved leg of `ExpandedPlayerPresentation.chapterRowState`'s
    // tri-state. Resolved at the displayed playhead (live once a session exists, else the retained
    // projection's saved position) to match the scrubber's scope: a chapter-scoped drag stays in
    // its chapter, so the row holds steady through a scrub.
    let chapterMap = ExpandedPlayerPresentation.resolvedChapterMap(
      itemID: itemID, episodeID: episodeID, loadedItemID: playback.loadedItemID,
      loadedEpisodeID: playback.loadedEpisodeID, playerItem: player.state.item,
      fallbackChapterMap: fallbackChapterMap)
    let currentChapter = chapterMap?.currentChapter(at: displayedTime)
    let chapterRowState = ExpandedPlayerPresentation.chapterRowState(
      episodeID: episodeID, chapterMap: chapterMap, currentChapter: currentChapter)
    let chapterNavigationEnabled =
      isTransportEnabled
      && ExpandedPlayerPresentation.isChapterAffordanceEnabled(chapterMap: chapterMap)

    return VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      // Title/author stay one combined element (identity before position); the chapter row below
      // is its own element. The block is leading-aligned so the overflow bubble can sit at its
      // trailing edge without the column reserving a matching empty gutter to stay optically
      // centred.
      HStack(alignment: .center, spacing: PlayerMetric.metadataOverflowSpacing) {
        VStack(alignment: .leading, spacing: titleBylineSpacing) {
          PlayerTitleText(title: title, author: author)

          authorRow(author: author)
        }

        if PlayerQuickActionsPresentation.showsOverflowMenu(episodeID: episodeID) {
          MetadataOverflowControl(
            itemID: itemID, episodeID: episodeID,
            duration: overflowDuration(liveItem: liveItem),
            playbackStatus: ExpandedPlayerPresentation.playbackStatus(
              itemID: itemID, episodeID: episodeID, displayedItem: playback.displayedItem,
              retainedPositionSeconds: playback.displayedItemPositionSeconds),
            playback: playback, actions: actions,
            includesHistory: PlayerQuickActionsPresentation.showsHistory(episodeID: episodeID),
            onShowHistory: onShowHistory, supplementCount: supplementCount,
            onShowSupplements: onShowSupplements, onViewDetails: onViewDetails,
            onAddBookmark: PlayerBookmarkPresentation.canAddBookmark(
              itemID: itemID, episodeID: episodeID, activeItemID: playback.activeItemID,
              loadedItemID: playback.loadedItemID, loadedEpisodeID: playback.loadedEpisodeID)
              ? onAddBookmark : nil,
            onShowTranscript: onShowTranscript,
            onShowLookBack: PlayerLookBackPresentation.isOffered(
              itemID: itemID, episodeID: episodeID, loadedItemID: playback.loadedItemID,
              loadedEpisodeID: playback.loadedEpisodeID,
              isRestoredAudiobook: playback.isRestoredAudiobook(itemID: itemID))
              ? onShowLookBack : nil
          )
          // The gate that keeps a position tick from rebuilding the menu source under an open
          // menu. This block's whole body re-runs every tick by design; the bubble's must not.
          .equatable()
        }
      }

      if ExpandedPlayerPresentation.chapterRowDrawsControl(for: chapterRowState) {
        chapterRow(
          state: chapterRowState, chapterMap: chapterMap,
          isNavigationEnabled: chapterNavigationEnabled)
      }
    }
    // The band takes the height its own lines need. Nothing below it is held still by a
    // reservation here: the page gives the band's variance to the cover above, so the scrubber,
    // transport, and quick-action row keep their places without this block holding open space it
    // does not draw in. See `ExpandedPlayerView.coverSize`.
    .padding(.horizontal, PlayerMetric.playerMetadataHorizontalPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// What "mark as finished" would write: the item-detail projection's length first, falling back
  /// to the live session's own timeline for an episode. `livePlayerItem` has already gated the
  /// item on identity, so a sibling episode can never lend its duration here.
  private func overflowDuration(liveItem: PlayerItem?) -> Double? {
    ExpandedPlayerPresentation.finishDurationSeconds(
      itemID: itemID, episodeID: episodeID, displayedItem: playback.displayedItem,
      itemDetailDurationSeconds: itemDetailDuration,
      liveTotalDuration: liveItem?.timeline.totalDuration)
  }

  /// The byline, flush with the title above it. Leading alignment means the overflow control
  /// beside it costs the line no matching gutter.
  private func authorRow(author: String?) -> some View {
    // Subheadline, not caption: a 12pt author under a 22pt title reads as a footnote the title
    // shed rather than the other half of the same credit.
    Group {
      if let bylineDestination {
        Button(action: onSelectByline) { bylineText(author) }
          .buttonStyle(.plain)
          .accessibilityLabel(author ?? "")
          .accessibilityHint(
            PlayerBylineNavigationPresentation.accessibilityHint(for: bylineDestination)
          )
          .accessibilityIdentifier(PlayerAccessibilityID.expandedByline)
      } else {
        bylineText(author)
          // Spoken as part of the title's own label, so non-interactive copy is silent.
          .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// A blank line, never an empty one, when an item has no byline: an empty `Text` measures
  /// nothing, so the band would lose the byline's height on exactly the items that have none.
  /// The quick-action labels reserve a blank line for the same reason.
  private func bylineText(_ author: String?) -> some View {
    Text(author ?? " ")
      .font(WhirrTypeToken.subheadline.font)
      .foregroundStyle(ExpandedPlayerPresentation.authorProminence.adaptiveStyle)
      .lineLimit(1)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Grown outward, not padded: the byline stays flush with the title above it, and a
      // `frame(minHeight:)` here would loosen that pairing to buy the same 44 points.
      .whirrMinimumHitTarget()
  }

  @ViewBuilder
  private func chapterRow(
    state: ExpandedPlayerPresentation.ChapterRowState, chapterMap: PlaybackChapterMap?,
    isNavigationEnabled: Bool
  ) -> some View {
    switch state {
    // Gated by `chapterRowDrawsControl` at the call site. Kept exhaustive rather than fatal, so
    // the empty leg is the safe one if that gate is loosened.
    case .hidden, .chapterless:
      EmptyView()
    case .reserved:
      chapterNavigationRow(
        label: "Chapters", spokenLabel: "Chapters", chapterMap: chapterMap,
        isSelectorEnabled: false, isNavigationEnabled: false)
    case .current(let label, let spokenLabel):
      chapterNavigationRow(
        label: label, spokenLabel: spokenLabel, chapterMap: chapterMap, isSelectorEnabled: true,
        isNavigationEnabled: isNavigationEnabled)
    }
  }

  /// Chapter changes are rare and coarse, so they sit with the chapter they change instead of
  /// bookending the everyday playback controls. Each symbol has a full minimum target and real
  /// separation from the selector, so the boundaries between the three actions stay predictable.
  private func chapterNavigationRow(
    label: String, spokenLabel: String, chapterMap: PlaybackChapterMap?, isSelectorEnabled: Bool,
    isNavigationEnabled: Bool
  ) -> some View {
    HStack(spacing: PlayerMetric.chapterNavigationSpacing) {
      chapterNavigationButton(
        direction: .previous, chapterMap: chapterMap, isEnabled: isNavigationEnabled)
      chapterButton(label: label, spokenLabel: spokenLabel, isEnabled: isSelectorEnabled)
      chapterNavigationButton(direction: .next, chapterMap: chapterMap, isEnabled: isNavigationEnabled)
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func chapterNavigationButton(
    direction: ExpandedPlayerPresentation.ChapterNavigationDirection, chapterMap: PlaybackChapterMap?,
    isEnabled: Bool
  ) -> some View {
    Button {
      guard let chapterMap else { return }
      Task {
        await playback.navigateChapter(
          itemID: itemID, episodeID: episodeID, forward: direction == .next,
          fallbackChapterMap: chapterMap)
      }
    } label: {
      Image(systemName: direction.systemImage)
        .font(.system(size: PlayerMetric.chapterNavigationSymbolSize, weight: .semibold))
        .foregroundStyle(.primary)
        .opacity(isEnabled ? 1 : 0.35)
        .frame(
          width: PlayerMetric.chapterNavigationButtonSize,
          height: PlayerMetric.chapterNavigationButtonSize
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isEnabled == false)
    .accessibilityLabel(direction.accessibilityLabel)
    .accessibilityHint(direction.accessibilityHint)
    .accessibilityIdentifier(
      direction == .previous
        ? PlayerAccessibilityID.expandedPreviousChapter
        : PlayerAccessibilityID.expandedNextChapter)
  }

  /// The chapter row's trigger for `ChapterSelectorSheet`, at the centre of the chapter stepper.
  /// The down chevron is a sheet disclosure cue, not a navigation push chevron.
  ///
  /// Label and chevron stay one intrinsic-width cluster so the stepper centres all three controls
  /// as a unit; a long name truncates rather than pushing the chevron out.
  private func chapterButton(label: String, spokenLabel: String, isEnabled: Bool) -> some View {
    Button {
      isShowingChapters = true
    } label: {
      HStack(spacing: PlayerMetric.chapterRowChevronSpacing) {
        // Static: the name is already its compact form, and nothing on this page moves.
        Text(label)
          .font(chapterFont)
          .lineLimit(1)
          .foregroundStyle(WhirrMetadataProminence.playerChapterRow.adaptiveStyle)
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(WhirrMetadataProminence.playerChapterRow.adaptiveStyle)
          .frame(width: PlayerMetric.chapterRowChevronWidth)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, PlayerMetric.chapterSelectorHorizontalPadding)
      .frame(
        minWidth: PlayerMetric.chapterSelectorButtonMinWidth,
        minHeight: PlayerMetric.chapterRowMinHeight
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isEnabled == false)
    .accessibilityLabel(spokenLabel)
    .accessibilityHint(ExpandedPlayerPresentation.chapterRowAccessibilityHint)
    .accessibilityIdentifier(PlayerAccessibilityID.expandedChapters)
  }

  private var displayedTime: Double {
    playback.displayedPositionSeconds(itemID: itemID, episodeID: episodeID, persisted: 0)
  }
}
