import ABSApi
import AppModel
import DesignSystem
import Persistence
import ReaderCore
import SwiftUI
import SyncEngine

struct ItemDetailActionRow: View {
  let item: ItemSummary
  let playback: PlaybackModel
  let isFinished: Bool
  let readAffordance: ReadAffordanceState
  let actionLayout: ItemDetailActionLayout
  /// The canvas's primary-action pair: the page's ink as the fill, and the page's own colour as
  /// the label on it. Neutral, so the capsule cannot clash with the ground however saturated.
  let accentFill: WhirrAccentPair
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onPresentChapters: () -> Void

  var body: some View {
    VStack(spacing: WhirrSpacing.small) {
      switch actionLayout {
      case .horizontal(let controls):
        horizontalActions(for: item, controls: controls)
      case .stacked(let controls):
        stackedActions(for: item, controls: controls)
      }
      ItemDetailWatchStatusLine(itemID: item.serverItemId, playback: playback)
    }
  }

  /// The standard-size row puts the ways into this title around its primary action: Chapters,
  /// Play, and Read where the item has all three capabilities.
  ///
  /// Play and Read are peers (an audiobook + ebook has two equal ways in): same capsule, equal
  /// width.
  @ViewBuilder
  private func horizontalActions(
    for item: ItemSummary, controls: [ItemDetailActionLayout.Control]
  ) -> some View {
    HStack(spacing: WhirrSpacing.small) {
      ForEach(controls, id: \.self) { control in
        action(for: control, item: item, isAccessibilitySize: false)
      }
    }
  }

  /// Accessibility sizes turn the circles into labelled rows and put each secondary action below
  /// the primary one. This keeps the action vocabulary readable when the compact glyph layout no
  /// longer has enough room for its labels.
  @ViewBuilder
  private func stackedActions(
    for item: ItemSummary, controls: [ItemDetailActionLayout.Control]
  ) -> some View {
    VStack(spacing: WhirrSpacing.small) {
      ForEach(controls, id: \.self) { control in
        action(for: control, item: item, isAccessibilitySize: true)
      }
    }
  }

  @ViewBuilder
  private func action(
    for control: ItemDetailActionLayout.Control,
    item: ItemSummary,
    isAccessibilitySize: Bool
  ) -> some View {
    switch control {
    case .chapters:
      chaptersButton(isAccessibilitySize: isAccessibilitySize)
    case .play:
      playButton(for: item)
    case .read:
      readerButton(for: item)
    }
  }

  private func chaptersButton(isAccessibilitySize: Bool) -> some View {
    Button {
      onPresentChapters()
    } label: {
      if isAccessibilitySize {
        Label("Chapters", systemImage: "list.bullet")
          .font(.headline)
          .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      } else {
        // Sized from the touch-target metric because the capsules beside it derive their height
        // from it. `.headline` alone leaves this glyph short of theirs: `list.bullet` is a wide,
        // short mark and draws about 3pt below `play.fill`/`book.fill`. The scale step closes that
        // optically while still tracking Dynamic Type, which a literal point size would not.
        Image(systemName: "list.bullet")
          .font(.headline)
          .imageScale(.large)
          .frame(
            minWidth: WhirrMetric.minimumTouchTarget,
            minHeight: WhirrMetric.minimumTouchTarget
          )
      }
    }
    .modifier(
      ChaptersActionStyle(isAccessibilitySize: isAccessibilitySize, accentFill: accentFill)
    )
    .accessibilityLabel("Chapters")
    .accessibilityHint("Shows all chapters.")
  }

  /// Read always keeps its visible title, whatever else the item can do. A missing title leaves
  /// only the Chapters opener on an ebook, since its parsed contents do not depend on reader
  /// availability.
  @ViewBuilder
  private func readerButton(for item: ItemSummary) -> some View {
    if let title = ReaderDetailCopy.detailActionTitle(
      for: readAffordance, isFinished: isFinished)
    {
      Button {
        onPresentReader(item.serverItemId, item.title, item.category)
      } label: {
        Label(title, systemImage: "book.fill")
          .labelStyle(.titleAndIcon)
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
          .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
      }
      .modifier(ItemDetailPrimaryActionStyle(accentFill: accentFill))
      .accessibilityIdentifier(ItemDetailReaderAccessibilityID.readButton)
      .accessibilityLabel(readerActionAccessibilityLabel(title: title))
      .accessibilityHint(
        readAffordance == .read
          ? "Opens this book in the reader."
          : "Opens this book at your saved reading position.")
    }
  }

  /// VoiceOver reads one label rather than the visible parenthetical, so the spoken form keeps the
  /// percentage the way `ReaderDetailCopy.continueReading` already words it.
  private func readerActionAccessibilityLabel(title: String) -> String {
    guard isFinished == false, case .continueReading(let percent) = readAffordance else {
      return title
    }
    return ReaderDetailCopy.continueReading(percent: percent)
  }

  /// Starts playback of this item, or toggles play/pause if it is already this device's active
  /// session (`PlaybackModel.start` is idempotent, so re-preparing would be a no-op resume).
  ///
  /// Carries its own tint, not the screen's ink: `accentFill` is the canvas's primary-action
  /// surface with a foreground that clears AA (dark capsule on pale paper, cover-coloured on deep).
  private func playButton(for item: ItemSummary) -> some View {
    ItemDetailPlaybackButton(
      item: item, playback: playback, isFinished: isFinished, accentFill: accentFill)
  }
}

/// The primary capsule treatment for Play and Read alike, down to the accent pair (any difference
/// would read as a recommendation). `.titleAndIcon` is stated because a squeezed width can reflow
/// the automatic style into a tall stack; `lineLimit` and `minimumScaleFactor` bound only text.
private struct ItemDetailPrimaryActionStyle: ViewModifier {
  let accentFill: WhirrAccentPair

  func body(content: Content) -> some View {
    content
      .tint(accentFill.fill.color)
      .foregroundStyle(accentFill.ink.color)
      .buttonStyle(.glassProminent)
      .buttonBorderShape(.capsule)
  }
}

/// The row's one secondary control, drawn in the page's own ink at a lower rung than the capsules.
///
/// No glass style works: glass resolves against the device colour scheme while the canvas comes
/// from the artwork (`AmbientCanvas.mode`), so on a pale cover the capsules go dark and glass goes
/// bright, making this the lightest thing in the row.
///
/// The disc is the page's ink at a low rung: `accentFill`'s `fill` (canvas ink) blended toward its
/// `ink` (page colour) lands a subtle disc on either pole, differing from the capsules by rung,
/// never direction. Blended here, not `.opacity`: `.glassProminent` (which holds all three
/// controls to one height) lets a translucent tint fall through to scheme-driven material, while
/// an opaque tint is honoured.
private struct ChaptersActionStyle: ViewModifier {
  let isAccessibilitySize: Bool
  let accentFill: WhirrAccentPair

  /// How far the disc travels from the page colour toward its ink. Enough to read as a pressable
  /// surface, little enough to stay a rung below the capsules.
  static let discRung: Double = 0.14

  /// The page colour carried `discRung` of the way toward the page ink, opaque.
  private var disc: Color {
    let page = accentFill.ink
    let ink = accentFill.fill
    func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * Self.discRung }
    return WhirrRGBColor(
      mix(page.red, ink.red), mix(page.green, ink.green), mix(page.blue, ink.blue)
    ).color
  }

  func body(content: Content) -> some View {
    if isAccessibilitySize {
      content.buttonStyle(.bordered)
    } else {
      content
        .tint(disc)
        .foregroundStyle(accentFill.fill.color)
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
    }
  }
}

/// The animation identity of the play control: the flags that change its glyph and its verb,
/// excluding the ticking remaining-time copy.
private struct PlaybackIntentSnapshot: Equatable {
  let isActive: Bool
  let isPlaying: Bool
  let isFinished: Bool
}

/// The item detail page's only live-playhead reader. Keeping it in a leaf view means the
/// twice-per-second progress stream updates the button's remaining-time label without rebuilding
/// the surrounding scroll view, hero artwork, palette background, or tab content.
private struct ItemDetailPlaybackButton: View {
  let item: ItemSummary
  let playback: PlaybackModel
  let isFinished: Bool
  let accentFill: WhirrAccentPair
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// The same figure Details prints, under the same gate, so the capsule and the table can never
  /// disagree about a title's length.
  private var unstartedDurationText: String? {
    guard let durationSeconds = item.durationSeconds,
      ItemDetailDurationPresentation.showsDuration(
        category: item.category, durationSeconds: durationSeconds)
    else { return nil }
    return ItemDetailViewPresentation.formattedDuration(durationSeconds)
  }

  var body: some View {
    let isActive = playback.activeItemID == item.serverItemId
    let isPlaying = isActive && playback.isPlaybackIntended
    let positionSeconds = ItemDetailPlayButtonPresentation.displayedPositionSeconds(
      item: item, playback: playback)
    let label = ItemDetailPlayButtonPresentation.label(
      isActive: isActive,
      isPlaying: isPlaying,
      positionSeconds: positionSeconds,
      isFinished: isFinished,
      durationSeconds: item.durationSeconds,
      playbackRate: playback.effectiveRate(for: item.serverItemId),
      unstartedDurationText: unstartedDurationText
    )
    let motion = ItemDetailPlayButtonPresentation.motion(reduceMotion: reduceMotion)
    let takesOver = CompanionDeviceIndicatorPresentation.shows(
      watchPlaying: playback.isPlayingOnCompanion(itemID: item.serverItemId, episodeID: nil),
      playingHere: isPlaying)
    return Button {
      guard ItemDetailPlayButtonPresentation.acceptsTap(phase: playback.phase, isActive: isActive)
      else { return }
      if isPlaying {
        playback.togglePlayPause()
      } else if isFinished {
        Task { await playback.start(itemID: item.serverItemId, fromStart: true) }
      } else if isActive {
        playback.togglePlayPause()
      } else {
        Task { await playback.start(itemID: item.serverItemId) }
      }
    } label: {
      Label {
        Text(label)
          .contentTransition(motion.textTransition)
      } icon: {
        Image(
          systemName: ItemDetailPlayButtonPresentation.symbolName(
            isPlaying: isPlaying, isFinished: isFinished)
        )
        .contentTransition(motion.symbolTransition)
      }
      .labelStyle(.titleAndIcon)
      .font(.headline)
      .lineLimit(1)
      .minimumScaleFactor(0.75)
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget)
    }
    .modifier(ItemDetailPrimaryActionStyle(accentFill: accentFill))
    // Animate on the intent itself rather than on the label: the remaining-time copy re-derives
    // twice a second from the live playhead, and animating that would leave the button perpetually
    // in transition. `isActive` and `isFinished` are carried too so activation and replay reset
    // animate identically to the play/pause transition.
    .animation(
      motion.controlAnimation,
      value: PlaybackIntentSnapshot(
        isActive: isActive, isPlaying: isPlaying, isFinished: isFinished)
    )
    .accessibilityIdentifier(ScreenAccessibilityID.itemDetailPlayButton)
    .accessibilityHint(
      isPlaying
        ? ""
        : takesOver
          ? CompanionDeviceIndicatorPresentation.takeOverHint
          : isFinished
            ? "Starts playing this title from the beginning."
            : isActive ? "" : "Starts playing this title from where you left off."
    )
  }
}
