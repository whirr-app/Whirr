import SnapshotTesting
import SwiftUI
import Testing

@testable import DesignSystem

// Assertions are against plain stored properties and pure functions, as in the rest of
// DesignSystemTests. `.dump` snapshots don't render a SwiftUI body (no UIKit host on macOS), so
// accessibility labels, values, hints, traits and hit-target sizes are exposed as testable data
// rather than only being applied inside `body`.
@Suite("Player components")
@MainActor
struct PlayerComponentTests {

  // MARK: - Player tokens (touch targets meet WhirrMetric.minimumTouchTarget)

  @Test("player metrics meet the documented 44pt minimum touch target where the metric sizes a tappable control")
  func playerMetricsMeetMinimumTouchTarget() {
    #expect(PlayerMetric.miniPlayerPlayPauseSize >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.transportPrimaryButtonSize >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.transportSecondaryButtonSize >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.chapterNavigationButtonSize >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.chapterSelectorButtonMinWidth >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.scrubberHitTargetHeight >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.chapterRowMinHeight >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.miniPlayerExpandTargetMinHeight >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.metadataOverflowTargetDiameter >= WhirrMetric.minimumTouchTarget)
  }

  /// The chrome's seams are a budget, not free space. The page's no-scroll invariant is stated
  /// over the chrome's total height, so a seam that grows has to be paid for by one that shrinks.
  /// Removing a row must not hand its frame back to the page, so the seams keep summing to 80.
  @Test("the chrome's seams still sum to their budget")
  func chromeSeamsSumToTheirBudget() {
    let seams =
      PlayerMetric.chromeTopSeam
      + PlayerMetric.chromeScrubberToTransportSpacing
      + PlayerMetric.chromeTransportToQuickActionsSpacing
    #expect(seams == 80)

    // The transport is the page's centre of gravity; the seam below it stays under the one that
    // sets it apart from the timeline, or the quick actions stop reading as a footer.
    #expect(
      PlayerMetric.chromeTransportToQuickActionsSpacing
        < PlayerMetric.chromeScrubberToTransportSpacing)
    #expect(PlayerMetric.chromeTopSeam < PlayerMetric.chromeTransportToQuickActionsSpacing)
  }

  /// The overflow bubble's drawn size and hit target differ. Drawn at the touch minimum it reads
  /// as a second focal point beside the title, so it draws smaller and pads out to the target.
  /// That only works while the two stay separate numbers.
  @Test("the overflow bubble draws smaller than the target it pads out to")
  func overflowBubbleDrawsInsideALargerTarget() {
    #expect(PlayerMetric.metadataOverflowDiameter < PlayerMetric.metadataOverflowTargetDiameter)
    #expect(PlayerMetric.metadataOverflowSymbolSize < PlayerMetric.metadataOverflowDiameter)
  }

  /// The margin has to land on the drawn circle, not the invisible target around it, or the disc
  /// reads as tucked in from the title's leading edge. The call site pulls back by the overhang,
  /// so it must be half the difference. It must also stay small enough that the target hangs into
  /// the page gutter rather than off the screen.
  @Test("the overflow bubble's margin correction is half its target's overhang")
  func overflowBubbleOverhangIsHalfTheDifference() {
    #expect(
      PlayerMetric.metadataOverflowTargetOverhang * 2
        == PlayerMetric.metadataOverflowTargetDiameter - PlayerMetric.metadataOverflowDiameter)
    #expect(PlayerMetric.metadataOverflowTargetOverhang < PlayerMetric.playerMetadataHorizontalPadding)
  }

  /// The title column gives up the bubble's occupied width plus the gap, and the wrap must still
  /// hold more title than the full column did. Otherwise titles fall through to the single
  /// scrolling line, which rests truncated after its one reveal and shows less than the wrap.
  /// Measured against the column the metadata block gets on a 393pt device, where the page inset
  /// is `WhirrSpacing.large` and the block adds its own on top.
  @Test("the title's line budget holds more than the column held before the bubble took its width")
  func titleLineBudgetOutholdsTheWidthTheBubbleTook() {
    let column = 393 - (WhirrSpacing.large + PlayerMetric.playerMetadataHorizontalPadding) * 2
    let bubbleCost =
      PlayerMetric.metadataOverflowTargetDiameter - PlayerMetric.metadataOverflowTargetOverhang
      + PlayerMetric.metadataOverflowSpacing
    let titleColumn = column - bubbleCost

    #expect(titleColumn > 0)
    #expect(CGFloat(PlayerMetric.metadataTitleLineBudget) * titleColumn > 2 * column)
  }

  /// The overflow control sits at the trailing edge and takes width the column already has, so the
  /// metadata column's padding is ordinary page padding and reserves no band on either side.
  @Test("the player's metadata column takes ordinary page padding and reserves nothing else")
  func playerMetadataColumnReservesNoControlBand() {
    #expect(PlayerMetric.playerMetadataHorizontalPadding < WhirrMetric.minimumTouchTarget)
  }

  /// Artwork is not a control, so the Up Next sheet sizes it with its own metric rather than
  /// `WhirrMetric.minimumTouchTarget`, which would make covers read as postage stamps beside a
  /// two-line title. It is free to exceed the hit minimum.
  @Test("queue row artwork is sized by its own metric, larger than the touch-target minimum")
  func queueRowCoverIsSizedIndependentlyOfTouchTargets() {
    #expect(PlayerMetric.queueRowCoverSize > WhirrMetric.minimumTouchTarget)
  }

  /// The `.default` animation took 433ms to swap the play/pause glyph and scaled it to nearly
  /// nothing midway, so an accepted tap still read as ignored. The transport's feedback has to
  /// land inside the window a tap is still felt as causing it.
  @Test("the play/pause glyph swap is short enough to read as the tap's own feedback")
  func transportSymbolTransitionReadsAsImmediate() {
    #expect(PlayerMetric.transportSymbolTransitionDuration > 0)
    #expect(PlayerMetric.transportSymbolTransitionDuration <= 0.15)
  }

  @Test("the swap is expressed to the symbol effect as a speed-up, never a slow-down")
  func transportSymbolTransitionSpeedOutrunsTheStockReplace() {
    #expect(PlayerMetric.transportSymbolTransitionSpeed > 1)
    #expect(
      PlayerMetric.systemSymbolReplaceDuration / PlayerMetric.transportSymbolTransitionSpeed
        == PlayerMetric.transportSymbolTransitionDuration)
  }

  /// The transaction only has to exist and be short; the symbol effect keeps its own timing.
  @Test("a play/pause change travels in an animated transaction the tap can outlive")
  func transportIntentAnimationIsDeclared() {
    #expect(PlayerMetric.transportIntentAnimation == .linear(duration: PlayerMetric.transportSymbolTransitionDuration))
  }

  // MARK: - Mini player (cover/title/play-pause/progress)

  @Test("mini player exposes caller-supplied title, subtitle, progress value, and play-pause label")
  func miniPlayerExposesCallerSuppliedCopy() {
    var expandTapped = false
    var playPauseTapped = false
    var progressResolutionCount = 0
    let miniPlayer = MiniPlayerView(
      title: "Project Hail Mary",
      subtitle: "Andy Weir",
      isPlaying: true,
      playPauseAccessibilityLabel: "Pause",
      skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 30 seconds",
      skipBackSystemImage: "gobackward.30",
      skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds",
      skipForwardSystemImage: "goforward.30",
      progressAccessibilityValue: {
        progressResolutionCount += 1
        return "2 hours 14 minutes remaining"
      },
      expandAccessibilityHint: "Double tap to open the full player",
      coverAccessibilityLabel: nil,
      contentColorScheme: .light,
      cover: { Color.clear },
      onPlayPauseTap: { playPauseTapped = true },
      onSkipBackTap: {},
      onSkipForwardTap: {},
      onExpandTap: { expandTapped = true }
    )

    #expect(miniPlayer.title == "Project Hail Mary")
    #expect(miniPlayer.subtitle == "Andy Weir")
    #expect(miniPlayer.isPlaying == true)
    #expect(miniPlayer.playPauseAccessibilityLabel == "Pause")
    #expect(progressResolutionCount == 0, "the accessibility value stays lazy until its leaf renders")
    #expect(miniPlayer.progressAccessibilityValue() == "2 hours 14 minutes remaining")
    #expect(progressResolutionCount == 1)
    #expect(miniPlayer.expandAccessibilityHint == "Double tap to open the full player")

    miniPlayer.onPlayPauseTap()
    miniPlayer.onExpandTap()
    #expect(playPauseTapped)
    #expect(expandTapped)
  }

  @Test("mini player keeps the status glyph caller-supplied and out of its spoken label")
  func miniPlayerStatusGlyphDoesNotChangeItsSpokenLabel() {
    let miniPlayer = MiniPlayerView(
      title: "Project Hail Mary",
      subtitle: "Offline",
      subtitleSystemImage: "wifi.slash",
      isPlaying: false,
      playPauseAccessibilityLabel: "Play",
      skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 30 seconds",
      skipBackSystemImage: "gobackward.30",
      skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds",
      skipForwardSystemImage: "goforward.30",
      progressAccessibilityValue: { "2 hours remaining" },
      expandAccessibilityHint: "Double tap to open the full player",
      coverAccessibilityLabel: nil,
      contentColorScheme: .light,
      cover: { Color.clear },
      onPlayPauseTap: {}, onSkipBackTap: {}, onSkipForwardTap: {}, onExpandTap: {})

    #expect(miniPlayer.subtitleSystemImage == "wifi.slash")
    #expect(miniPlayer.combinedAccessibilityLabel == "Project Hail Mary, Offline")
  }

  @Test("mini player uses a marquee below accessibility Dynamic Type sizes")
  func miniPlayerUsesTitleMarqueeOnlyBelowAccessibilitySizes() {
    #expect(MiniPlayerView<Color, EmptyView>.usesTitleMarquee(isAccessibilitySize: false))
    #expect(MiniPlayerView<Color, EmptyView>.usesTitleMarquee(isAccessibilitySize: true) == false)
  }

  @Test("mini player stores title marquee activity in both accessory layouts")
  func miniPlayerStoresTitleMarqueeActivityInBothLayouts() {
    #expect(makeMiniPlayer(layout: .inline, isTitleMarqueeActive: true).isTitleMarqueeActive)
    #expect(
      makeMiniPlayer(layout: .expanded, isTitleMarqueeActive: false).isTitleMarqueeActive == false)
  }

  @Test("mini player play-pause control meets the 44pt minimum hit target")
  func miniPlayerPlayPauseMeetsMinimumHitTarget() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.playPauseButtonSize >= WhirrMetric.minimumTouchTarget)
  }

  /// A tab-bar accessory can independently choose light or dark glass vibrancy while it animates
  /// between expanded and inline placements. The component must name a semantic foreground of its
  /// own instead of allowing that transient inherited tint to turn every label and glyph white.
  @Test("mini player content owns a primary semantic foreground")
  func miniPlayerOwnsPrimaryForeground() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.contentForegroundStyle == .primary)
    #expect(miniPlayer.subtitleForegroundStyle == .secondary)
  }

  /// Both roles stay anchored to semantic primary ink so they keep following the caller's
  /// presentation scheme once it has been carried into the accessory host.
  @Test("mini player foreground roles resolve against primary ink")
  func miniPlayerForegroundRolesResolveAgainstPrimaryInk() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.contentForegroundStyle.color == Color.primary)
    #expect(
      miniPlayer.subtitleForegroundStyle.color
        == Color.primary.opacity(miniPlayer.subtitleForegroundStyle.opacity))
  }

  /// The subtitle is caption-sized, so it owes 4.5:1. System `.secondary` measured 3.72:1 on the
  /// plain glass over Home and 2.68:1 on the glass over a coral item-detail page, because the glass
  /// takes on whatever is behind it. The grounds are those two captures plus the dark paper.
  @Test("mini player subtitle clears AA on the glass it was measured on")
  func miniPlayerSubtitleClearsAA() {
    let opacity = makeMiniPlayer().subtitleForegroundStyle.opacity
    let lightGlass: [(String, WhirrRGBColor)] = [
      ("glass over Home", WhirrRGBColor(251.0 / 255.0, 251.0 / 255.0, 249.0 / 255.0)),
      ("glass over a coral page", WhirrRGBColor(254.0 / 255.0, 163.0 / 255.0, 144.0 / 255.0)),
    ]
    for (name, ground) in lightGlass {
      let ink = WhirrRGBColor(
        ground.red * (1 - opacity), ground.green * (1 - opacity), ground.blue * (1 - opacity))
      let ratio = contrastRatio(ink, ground)
      #expect(ratio >= 4.5, "\(name): \(String(format: "%.2f", ratio)):1")
    }
    let dark = WhirrColorToken.editorialBackground.darkRGB
    let darkInk = WhirrRGBColor(
      opacity + (1 - opacity) * dark.red, opacity + (1 - opacity) * dark.green,
      opacity + (1 - opacity) * dark.blue)
    #expect(contrastRatio(darkInk, dark) >= 4.5)
  }

  /// `tabViewBottomAccessory` renders its closure in a system-owned host whose vibrancy can expose
  /// a different color-scheme environment from the presenting shell. The component therefore has
  /// to carry the shell's already-resolved scheme across that boundary instead of resolving
  /// `.primary` in the accessory host.
  @Test("mini player carries the presenting shell color scheme into the accessory host")
  func miniPlayerCarriesPresentingColorScheme() {
    #expect(makeMiniPlayer(contentColorScheme: .light).contentColorScheme == .light)
    #expect(makeMiniPlayer(contentColorScheme: .dark).contentColorScheme == .dark)
  }

  /// The expand target is the title/subtitle region, whose intrinsic height is whatever two lines
  /// of text measure, so the 44pt minimum is asserted on the frame the component applies. Guards
  /// against tap-to-expand being unreliable because only the glyphs were hittable.
  @Test("mini player expand target meets the 44pt minimum hit target")
  func miniPlayerExpandTargetMeetsMinimumHitTarget() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.expandTargetMinHeight >= WhirrMetric.minimumTouchTarget)
  }

  @Test("mini player info region is read before the play-pause control (logical VoiceOver order)")
  func miniPlayerOrdersInfoBeforePlayPause() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.infoSortPriority > miniPlayer.playPauseSortPriority)
  }

  @Test("mini player cover is hidden from accessibility when redundant with the visible title")
  func miniPlayerCoverHiddenWhenRedundant() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.coverAccessibilityLabel == nil)
  }

  @Test("mini player cover carries a meaningful alternative when the caller supplies one")
  func miniPlayerCoverCarriesMeaningfulAlternative() {
    let miniPlayer = makeMiniPlayer(coverAccessibilityLabel: "Cover art for Title")
    #expect(miniPlayer.coverAccessibilityLabel == "Cover art for Title")
  }

  // MARK: - Mini player bare ±30 skip controls

  private func makeMiniPlayer(
    layout: MiniPlayerLayout = .expanded,
    contentMaxWidth: CGFloat? = nil,
    isTitleMarqueeActive: Bool = false,
    contentColorScheme: ColorScheme = .light,
    coverAccessibilityLabel: String? = nil,
    isTransportEnabled: Bool = true,
    onPlayPauseTap: @escaping () -> Void = {},
    onSkipBackTap: @escaping () -> Void = {},
    onSkipForwardTap: @escaping () -> Void = {},
    onExpandTap: @escaping () -> Void = {}
  ) -> MiniPlayerView<Color, EmptyView> {
    MiniPlayerView(
      title: "Project Hail Mary", subtitle: "Andy Weir", isPlaying: false,
      playPauseAccessibilityLabel: "Play",
      skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 30 seconds",
      skipBackSystemImage: "gobackward.30",
      skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds",
      skipForwardSystemImage: "goforward.30",
      progressAccessibilityValue: { "1 hour remaining" },
      expandAccessibilityHint: "Double tap to open the full player",
      coverAccessibilityLabel: coverAccessibilityLabel,
      layout: layout,
      contentMaxWidth: contentMaxWidth,
      isTitleMarqueeActive: isTitleMarqueeActive,
      contentColorScheme: contentColorScheme,
      isTransportEnabled: isTransportEnabled,
      cover: { Color.clear }, onPlayPauseTap: onPlayPauseTap, onSkipBackTap: onSkipBackTap,
      onSkipForwardTap: onSkipForwardTap, onExpandTap: onExpandTap
    )
  }

  @Test("mini player lets the system bottom accessory own the glass surface")
  func miniPlayerDoesNotNestCustomGlassInsideTheSystemAccessory() {
    let miniPlayer = makeMiniPlayer()
    var dumped = ""
    dump(miniPlayer.body, to: &dumped)
    #expect(!dumped.contains("GlassContainer"))
  }

  @Test("inline mini player preserves cover, metadata, and play-pause by removing skip controls")
  func inlineMiniPlayerUsesTheAppleMusicInformationHierarchy() {
    let miniPlayer = makeMiniPlayer(layout: .inline)
    #expect(miniPlayer.layout == .inline)
    #expect(miniPlayer.showsSkipControls == false)
  }

  @Test("expanded mini player keeps the full audiobook transport cluster")
  func expandedMiniPlayerKeepsSkipControls() {
    let miniPlayer = makeMiniPlayer(layout: .expanded)
    #expect(miniPlayer.layout == .expanded)
    #expect(miniPlayer.showsSkipControls)
  }

  @Test("mini player draws a caller's accessory cluster only in the expanded layout")
  func miniPlayerAccessoryFollowsTheExpandedLayout() {
    func withAccessory(_ layout: MiniPlayerLayout) -> MiniPlayerView<Color, Text> {
      MiniPlayerView(
        title: "Project Hail Mary", subtitle: "Andy Weir", isPlaying: false,
        playPauseAccessibilityLabel: "Play",
        skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 30 seconds",
        skipBackSystemImage: "gobackward.30",
        skipForwardAccessibilityLabel: "Skip forward",
        skipForwardAccessibilityHint: "Skips forward 30 seconds",
        skipForwardSystemImage: "goforward.30",
        progressAccessibilityValue: { "1 hour remaining" },
        expandAccessibilityHint: "Double tap to open the full player",
        coverAccessibilityLabel: nil, layout: layout, contentColorScheme: .light,
        cover: { Color.clear }, accessory: { Text("1.5×") },
        onPlayPauseTap: {}, onSkipBackTap: {}, onSkipForwardTap: {}, onExpandTap: {})
    }
    #expect(withAccessory(.expanded).showsAccessory)
    #expect(withAccessory(.inline).showsAccessory == false)
  }

  @Test("mini player takes the whole width it is offered when the caller sets no cap")
  func miniPlayerIsUncappedByDefault() {
    #expect(makeMiniPlayer().contentMaxWidth == nil)
  }

  @Test("mini player honours a caller-supplied width cap")
  func miniPlayerHonoursTheCallerSuppliedWidthCap() {
    #expect(makeMiniPlayer(contentMaxWidth: 460).contentMaxWidth == 460)
  }

  @Test("mini player forwards skip-back, skip-forward, and play-pause to the correct, distinct closures")
  func miniPlayerForwardsSkipBackSkipForwardAndPlayPauseToTheCorrectClosures() {
    var skippedBack = false
    var playPaused = false
    var skippedForward = false
    let miniPlayer = makeMiniPlayer(
      onPlayPauseTap: { playPaused = true },
      onSkipBackTap: { skippedBack = true },
      onSkipForwardTap: { skippedForward = true }
    )

    miniPlayer.onSkipBackTap()
    #expect(skippedBack)
    #expect(!playPaused)
    #expect(!skippedForward)

    skippedBack = false
    miniPlayer.onPlayPauseTap()
    #expect(playPaused)
    #expect(!skippedBack)
    #expect(!skippedForward)

    playPaused = false
    miniPlayer.onSkipForwardTap()
    #expect(skippedForward)
    #expect(!skippedBack)
    #expect(!playPaused)
  }

  @Test("mini player skip controls meet the 44pt minimum touch target")
  func miniPlayerSkipControlsMeetTheMinimumTouchTarget() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.skipButtonSize >= WhirrMetric.minimumTouchTarget)
  }

  /// Every point between the transport controls is a point the title column does not get, and the
  /// 44pt targets already hold their glyphs more than 20pt apart. The cluster is packed, and its
  /// targets stay at the HIG minimum rather than shrinking to make room.
  @Test("mini player transport controls sit edge to edge without shrinking their targets")
  func miniPlayerTransportControlsArePacked() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.transportSpacing == 0)
    #expect(miniPlayer.skipButtonSize >= WhirrMetric.minimumTouchTarget)
    #expect(miniPlayer.playPauseButtonSize >= WhirrMetric.minimumTouchTarget)
  }

  @Test("mini player play button has no circular background - bare symbol like the transport controls")
  func miniPlayerHasNoCircularPlayButtonBackground() {
    let miniPlayer = makeMiniPlayer()
    var dumped = ""
    dump(miniPlayer.body, to: &dumped)
    #expect(!dumped.contains("Circle"))
  }

  @Test(
    "mini player VoiceOver order is info, then skip-back, then play-pause, then skip-forward (logical left-to-right order)"
  )
  func miniPlayerVoiceOverOrderIsInfoThenSkipBackThenPlayPauseThenSkipForward() {
    let miniPlayer = makeMiniPlayer()
    #expect(miniPlayer.infoSortPriority > miniPlayer.skipBackSortPriority)
    #expect(miniPlayer.skipBackSortPriority > miniPlayer.playPauseSortPriority)
    #expect(miniPlayer.playPauseSortPriority > miniPlayer.skipForwardSortPriority)
  }

  /// Whether SwiftUI blocks a tap because of `.disabled(!isTransportEnabled)` on the three
  /// transport buttons cannot be observed by a non-rendering macOS-host test (no UIKit host, and
  /// the flag is captured in a closure reflection can't see through). That is checked on device.
  /// What is verifiable here: `isTransportEnabled: false` does not couple the flag to
  /// `onExpandTap`, so the expand closure stays reachable.
  @Test("mini player's disabled state disables the transport controls but not the expand target")
  func miniPlayerDisabledStateDisablesTransportButNotTheExpandTarget() {
    var skippedBack = false
    var playPaused = false
    var skippedForward = false
    var expanded = false
    let miniPlayer = makeMiniPlayer(
      isTransportEnabled: false,
      onPlayPauseTap: { playPaused = true },
      onSkipBackTap: { skippedBack = true },
      onSkipForwardTap: { skippedForward = true },
      onExpandTap: { expanded = true }
    )
    #expect(!miniPlayer.isTransportEnabled)

    miniPlayer.onExpandTap()
    #expect(expanded)
    #expect(!skippedBack)
    #expect(!playPaused)
    #expect(!skippedForward)
  }

  /// The mini player is hosted in `.tabViewBottomAccessory`, whose budget is roughly 60pt. This
  /// sums the fixed-size contributors (the 44pt cover, expand and transport controls, none able to
  /// shrink below the touch-target minimum) plus the row's vertical padding, from the tokens `body`
  /// uses, since this macOS host cannot measure a view. The 44pt floor comes from
  /// `PlayerMetric.miniPlayerCoverSize` and `.miniPlayerExpandTargetMinHeight`; the only free
  /// lever is the row's vertical padding (`WhirrSpacing.xxSmall` in `body`).
  @Test("mini player's fixed-size content fits within the ~60pt accessory height budget, before Dynamic Type growth")
  func miniPlayerContentFitsTheAccessoryHeightBudgetAtLargeDynamicType() {
    let miniPlayer = makeMiniPlayer()
    let verticalPadding = WhirrSpacing.xxSmall * 2
    let fixedRowHeight = max(
      PlayerMetric.miniPlayerCoverSize, miniPlayer.playPauseButtonSize, miniPlayer.skipButtonSize,
      miniPlayer.expandTargetMinHeight
    )
    let structuralMinimumHeight = fixedRowHeight + verticalPadding
    let accessoryHeightBudget: CGFloat = 60
    #expect(structuralMinimumHeight <= accessoryHeightBudget)
    #expect(miniPlayer.playPauseButtonSize >= WhirrMetric.minimumTouchTarget)
    #expect(miniPlayer.skipButtonSize >= WhirrMetric.minimumTouchTarget)
  }

  // MARK: - Full transport cluster

  @Test("transport controls expose caller-supplied labels/hints and forward taps to the right action")
  func transportControlsExposeCopyAndForwardTaps() {
    var skippedBack = false
    var playPaused = false
    var skippedForward = false
    let controls = TransportControlsView(
      isPlaying: true,
      playPauseAccessibilityLabel: "Pause",
      playPauseSystemImage: "pause.fill",
      skipBackAccessibilityLabel: "Skip back",
      skipBackAccessibilityHint: "Skips back 15 seconds",
      skipBackSystemImage: "gobackward.15",
      skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds",
      skipForwardSystemImage: "goforward.30",
      onPlayPauseTap: { playPaused = true },
      onSkipBackTap: { skippedBack = true },
      onSkipForwardTap: { skippedForward = true }
    )

    #expect(controls.playPauseAccessibilityLabel == "Pause")
    #expect(controls.skipBackAccessibilityHint == "Skips back 15 seconds")
    #expect(controls.skipForwardAccessibilityHint == "Skips forward 30 seconds")

    controls.onPlayPauseTap()
    controls.onSkipBackTap()
    controls.onSkipForwardTap()
    #expect(playPaused)
    #expect(skippedBack)
    #expect(skippedForward)
  }

  @Test("transport control buttons meet the 44pt minimum hit target")
  func transportControlsMeetMinimumHitTarget() {
    let controls = TransportControlsView(
      isPlaying: false, playPauseAccessibilityLabel: "Play", playPauseSystemImage: "play.fill",
      skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 15 seconds",
      skipBackSystemImage: "gobackward.15", skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds", skipForwardSystemImage: "goforward.30",
      onPlayPauseTap: {}, onSkipBackTap: {}, onSkipForwardTap: {}
    )
    #expect(controls.playPauseButtonSize >= WhirrMetric.minimumTouchTarget)
    #expect(controls.skipButtonSize >= WhirrMetric.minimumTouchTarget)
  }

  /// The middle tier (the two skips) is a bare glyph, so its symbol size is all of its presence
  /// and has to sit well above body-text size. The discs on either side carry their own
  /// hierarchy (`transportDiscsCarryTheHierarchy`).
  @Test("skip icons are plain symbols, well above body-text size")
  func skipSymbolsArePlainAndProminent() {
    let controls = TransportControlsView(
      isPlaying: false, playPauseAccessibilityLabel: "Play", playPauseSystemImage: "play.fill",
      skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 15 seconds",
      skipBackSystemImage: "gobackward.15", skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds", skipForwardSystemImage: "goforward.30",
      onPlayPauseTap: {}, onSkipBackTap: {}, onSkipForwardTap: {}
    )
    #expect(controls.playPauseSymbolSize == PlayerMetric.transportPrimarySymbolSize)
    #expect(controls.skipSymbolSize == PlayerMetric.transportSecondarySymbolSize)
    #expect(PlayerMetric.transportSecondarySymbolSize >= 28)
  }

  /// The only transport disc is the primary action. Its glyph still has to fit inside the disc,
  /// and the disc inside the full hit target.
  @Test("the play-pause disc and glyph fit their containers")
  func discsAndGlyphsFitTheirContainers() {
    let controls = makeTransportControls()

    #expect(controls.playPauseDiscSize <= controls.playPauseButtonSize)
    #expect(controls.playPauseSymbolSize < controls.playPauseDiscSize)
  }

  /// The fill is the caller's. The expanded player hands it the cover's accent, the colour the
  /// item-detail Resume button is tinted with. A surface that supplies none keeps the neutral
  /// primary.
  @Test("the play/pause disc takes the caller's fill, and defaults to neutral")
  func playPauseDiscTakesTheCallersFill() {
    let tinted = TransportControlsView(
      isPlaying: false, playPauseAccessibilityLabel: "Play", playPauseSystemImage: "play.fill",
      skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 15 seconds",
      skipBackSystemImage: "gobackward.15", skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds", skipForwardSystemImage: "goforward.30",
      onPlayPauseTap: {}, onSkipBackTap: {}, onSkipForwardTap: {},
      playPauseFill: .orange
    )

    #expect(tinted.playPauseFill == .orange)
    #expect(makeTransportControls().playPauseFill == .primary)
  }

  @Test("transport controls order skip-back, play-pause, skip-forward for VoiceOver (logical left-to-right order)")
  func transportControlsHaveLogicalVoiceOverOrder() {
    let controls = TransportControlsView(
      isPlaying: false, playPauseAccessibilityLabel: "Play", playPauseSystemImage: "play.fill",
      skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 15 seconds",
      skipBackSystemImage: "gobackward.15", skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds", skipForwardSystemImage: "goforward.30",
      onPlayPauseTap: {}, onSkipBackTap: {}, onSkipForwardTap: {}
    )
    #expect(controls.skipBackSortPriority > controls.playPauseSortPriority)
    #expect(controls.playPauseSortPriority > controls.skipForwardSortPriority)
  }

  /// Chapter jumps sit beside the chapter label rather than competing with playback. Their
  /// visible symbols are smaller than the seconds-scale skips, while their invisible targets stay
  /// full sized.
  @Test("chapter navigation is quiet without sacrificing its hit target")
  func chapterNavigationIsQuietAndTappable() {
    #expect(PlayerMetric.chapterNavigationButtonSize >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.chapterSelectorButtonMinWidth >= WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.chapterNavigationSpacing >= WhirrSpacing.xSmall)
    #expect(PlayerMetric.chapterSelectorHorizontalPadding >= WhirrSpacing.xSmall)
    #expect(PlayerMetric.chapterNavigationSymbolSize >= 18)
    #expect(PlayerMetric.chapterNavigationSymbolSize < PlayerMetric.transportSecondarySymbolSize)
  }

  private func makeTransportControls() -> TransportControlsView {
    TransportControlsView(
      isPlaying: false, playPauseAccessibilityLabel: "Play", playPauseSystemImage: "play.fill",
      skipBackAccessibilityLabel: "Skip back", skipBackAccessibilityHint: "Skips back 15 seconds",
      skipBackSystemImage: "gobackward.15", skipForwardAccessibilityLabel: "Skip forward",
      skipForwardAccessibilityHint: "Skips forward 30 seconds",
      skipForwardSystemImage: "goforward.30",
      onPlayPauseTap: {}, onSkipBackTap: {}, onSkipForwardTap: {}
    )
  }

  /// The quick-action row under the transport (sleep timer, speed, chapters, up next) must not sit
  /// at the bare 44pt minimum with footnote text, which reads as a caption strip rather than as
  /// controls. Both tokens that carry that are above the minimum.
  @Test("quick-action controls are sized above the bare touch-target minimum")
  func quickActionControlsAreLargerThanTheMinimum() {
    #expect(PlayerMetric.quickActionMinHeight > WhirrMetric.minimumTouchTarget)
    #expect(PlayerMetric.quickActionSymbolSize >= 17)
  }

  @Test(
    "quick-action minimum height stays standard-sized when Dynamic Type is standard and grows for accessibility sizes")
  func quickActionMinimumHeightResolvesPerDynamicTypeSize() {
    let standard = PlayerQuickActionLayoutValues.resolve(isAccessibilitySize: false)
    let accessibility = PlayerQuickActionLayoutValues.resolve(isAccessibilitySize: true)

    #expect(standard.minimumHeight == PlayerMetric.quickActionMinHeight)
    #expect(accessibility.minimumHeight > standard.minimumHeight)
  }

  @Test("quick-action labels wrap without scaling at accessibility sizes and preserve standard behavior")
  func quickActionLabelTextResolvesWrappingWithoutScalingAtAccessibilitySizes() {
    let standard = PlayerQuickActionLayoutValues.resolve(isAccessibilitySize: false)
    let accessibility = PlayerQuickActionLayoutValues.resolve(isAccessibilitySize: true)

    #expect(standard.labelLineLimit == 1)
    #expect(standard.minimumScaleFactor == 0.75)
    #expect(accessibility.labelLineLimit == nil)
    #expect(accessibility.minimumScaleFactor == nil)
  }

  @Test("quick-action minimum height meets the touch-target invariant at every resolved size")
  func quickActionMinimumHeightMeetsMinimumTouchTargetAtEveryResolvedSize() {
    let standard = PlayerQuickActionLayoutValues.resolve(isAccessibilitySize: false)
    let accessibility = PlayerQuickActionLayoutValues.resolve(isAccessibilitySize: true)

    #expect(standard.minimumHeight >= WhirrMetric.minimumTouchTarget)
    #expect(accessibility.minimumHeight >= WhirrMetric.minimumTouchTarget)
  }

  // MARK: - Stacked quick-action labels

  /// A quarter of the row's width cannot hold a glyph and a clock side by side (the timer would
  /// truncate to "19:…"), so the label sits beneath its glyph, where it has the whole slot.
  @Test("the quick-action glyph is drawn at a glyph's size, not a label's")
  func quickActionGlyphIsSizedForStandingAboveItsLabel() {
    #expect(PlayerMetric.quickActionSymbolSize > PlayerMetric.chapterNavigationSymbolSize)
    #expect(PlayerMetric.quickActionLabelSpacing < WhirrSpacing.xxSmall)
  }

  /// This row is secondary to the transport above it. Sized and weighted like the transport, it
  /// would read as a second headline rather than a quiet strip of settings. Every lever points
  /// the same way: smaller than the transport's glyphs, lighter in weight, and a readout under
  /// it rather than a title.
  @Test("the quick-action row is quieter than the transport it sits beneath")
  func quickActionRowRecedesBeneathTheTransport() {
    #expect(PlayerMetric.quickActionSymbolSize < PlayerMetric.transportSecondarySymbolSize)
  }

  /// Reserved for every control, labelled or not. Two controls never carry text and the other two
  /// only carry it while a setting is on; without a held line the four glyphs would sit at two
  /// different heights, and a timer starting would grow the row under a thumb.
  @Test("the label line under a glyph is reserved even when the control has nothing to say")
  func quickActionLabelLineIsReservedWhenThereIsNoTitle() {
    let blank = PlayerQuickActionLayoutValues.labelLine(for: nil)

    let isAllWhitespace = blank.allSatisfy { $0.isWhitespace }

    #expect(blank.isEmpty == false)
    #expect(isAllWhitespace)
  }

  @Test("a titled quick action draws its title on that same line")
  func quickActionLabelLinePassesATitleThrough() {
    #expect(PlayerQuickActionLayoutValues.labelLine(for: "19:23") == "19:23")
    #expect(PlayerQuickActionLayoutValues.labelLine(for: "1.5×") == "1.5×")
  }

  // MARK: - Adjustable scrubber

  @Test("scrubber exposes a caller-formatted elapsed/remaining accessibility value")
  func scrubberExposesFormattedAccessibilityValue() {
    let scrubber = PlaybackScrubber(
      progressFraction: 0.5,
      accessibilityLabel: "Playback position",
      accessibilityValue: "1 hour 2 minutes elapsed, 45 minutes remaining",
      onAdjust: { _ in }
    )
    #expect(scrubber.progressFraction == 0.5)
    #expect(scrubber.accessibilityLabel == "Playback position")
    #expect(scrubber.accessibilityValue == "1 hour 2 minutes elapsed, 45 minutes remaining")
  }

  @Test("scrubber exposes an adjustable action that forwards increment and decrement separately")
  func scrubberAdjustableActionForwardsIncrementAndDecrement() {
    var received: [PlaybackScrubber.AdjustmentDirection] = []
    let scrubber = PlaybackScrubber(
      progressFraction: 0.5, accessibilityLabel: "Playback position",
      accessibilityValue: "1 hour elapsed", onAdjust: { received.append($0) }
    )
    scrubber.onAdjust(.increment)
    scrubber.onAdjust(.decrement)
    #expect(received == [.increment, .decrement])
  }

  @Test("scrubber hit target meets the 44pt minimum independent of the thinner visual track")
  func scrubberHitTargetMeetsMinimum() {
    let scrubber = PlaybackScrubber(
      progressFraction: 0, accessibilityLabel: "Playback position", accessibilityValue: "0 minutes elapsed",
      onAdjust: { _ in }
    )
    #expect(scrubber.hitTargetHeight >= WhirrMetric.minimumTouchTarget)
  }

  @Test("scrubber's active (dragging) track is visibly taller than the idle track, both non-zero")
  func scrubberActiveTrackTallerThanIdle() {
    let scrubber = PlaybackScrubber(
      progressFraction: 0.5, accessibilityLabel: "Playback position",
      accessibilityValue: "1 hour elapsed", onAdjust: { _ in }
    )
    #expect(scrubber.visualTrackHeight > 0)
    #expect(scrubber.activeTrackHeight > scrubber.visualTrackHeight)
    #expect(PlayerMetric.scrubberActiveTrackHeight > PlayerMetric.scrubberVisualTrackHeight)
  }

  @Test("audio scrubber keeps its original visual style defaults")
  func audioScrubberKeepsOriginalVisualStyleDefaults() {
    let scrubber = PlaybackScrubber(
      progressFraction: 0.5,
      accessibilityLabel: "Playback position",
      accessibilityValue: "1 hour elapsed",
      onAdjust: { _ in }
    )

    #expect(scrubber.visualTrackHeight == PlayerMetric.scrubberVisualTrackHeight)
    #expect(scrubber.activeTrackHeight == PlayerMetric.scrubberActiveTrackHeight)
    #expect(scrubber.thumbDiameter == nil)
    #expect(scrubber.hitTargetHeight == PlayerMetric.scrubberHitTargetHeight)
  }

  @Test("scrubber forwards a direct seek fraction")
  func scrubberForwardsDirectSeekFraction() {
    var receivedFraction: Double?
    let scrubber = PlaybackScrubber(
      progressFraction: 0.25, accessibilityLabel: "Playback position", accessibilityValue: "15 minutes elapsed",
      onAdjust: { _ in }, onSeek: { receivedFraction = $0 }
    )

    scrubber.onSeek?(0.75)
    #expect(receivedFraction == 0.75)
  }

  @Test("scrubber forwards an in-flight scrub preview and its resolution")
  func scrubberForwardsScrubPreview() {
    var received: [ScrubPreview?] = []
    let scrubber = PlaybackScrubber(
      progressFraction: 0.25, accessibilityLabel: "Playback position", accessibilityValue: "15 minutes elapsed",
      onAdjust: { _ in }, onSeek: { _ in }, onScrub: { received.append($0) }
    )

    scrubber.onScrub?(ScrubPreview(fraction: 0.4, speed: .fine))
    scrubber.onScrub?(nil)
    #expect(received == [ScrubPreview(fraction: 0.4, speed: .fine), nil])
  }

  // MARK: - Scrubber fill geometry

  @Test("the fill is exactly proportional to the fraction")
  func fillWidthIsProportionalToFraction() {
    #expect(PlaybackScrubber.fillWidth(trackWidth: 354, fraction: 0.5) == 177)
    #expect(PlaybackScrubber.fillWidth(trackWidth: 354, fraction: 0.25) == 88.5)
  }

  @Test("an unstarted book shows no fill rather than a minimum-width stub")
  func fillWidthIsZeroAtTheStart() {
    #expect(PlaybackScrubber.fillWidth(trackWidth: 354, fraction: 0) == 0)
  }

  /// The fill must not be floored at the track's own height. On a ten-hour book that would render
  /// every position from 0 to ~12 minutes identically, leaving the bar frozen while the audio and
  /// the clock move.
  @Test("consecutive minutes of a ten-hour book render at distinguishable widths")
  func fillWidthResolvesMinutesOfATenHourBook() {
    let duration: Double = 36_960
    let widths = (0...12).map { minute in
      PlaybackScrubber.fillWidth(trackWidth: 354, fraction: Double(minute) * 60 / duration)
    }
    #expect(Set(widths).count == widths.count)
    #expect(widths.sorted() == widths)
  }

  @Test("the fill never overruns the track, whatever the caller reports")
  func fillWidthNeverExceedsTheTrack() {
    #expect(PlaybackScrubber.fillWidth(trackWidth: 354, fraction: 1) == 354)
    #expect(PlaybackScrubber.fillWidth(trackWidth: 354, fraction: 1.4) == 354)
    #expect(PlaybackScrubber.fillWidth(trackWidth: 354, fraction: -0.2) == 0)
  }

  @Test("a non-finite fraction or an unmeasured track draws nothing rather than NaN")
  func fillWidthGuardsUnusableInput() {
    #expect(PlaybackScrubber.fillWidth(trackWidth: 354, fraction: .nan) == 0)
    #expect(PlaybackScrubber.fillWidth(trackWidth: 0, fraction: 0.5) == 0)
    #expect(PlaybackScrubber.fillWidth(trackWidth: -10, fraction: 0.5) == 0)
  }

  @Test func scrubberTrackAnimationDisablesReduceMotion() {
    #expect(PlaybackScrubber.trackAnimation(reduceMotion: true) == nil)
    #expect(
      PlaybackScrubber.trackAnimation(reduceMotion: false)
        == .snappy(duration: 0.24))
  }

  // MARK: - Chapter row / list

  @Test("chapter row renders title and timing, completed state, optional indicator, and caller metadata")
  func chapterRowRendersTitleTimingCompletionIndicatorAndAccessibilityMetadata() {
    let completed = ChapterRow(
      title: "Chapter 3: The Signal",
      timingText: "00:42 · 18 min",
      isCurrent: false,
      isCompleted: true,
      trailingIndicatorSystemImage: "checkmark.circle.fill",
      accessibilityLabel: "Chapter 3, The Signal",
      accessibilityValue: "Starts at 42 seconds, 18 minutes long, completed",
      accessibilityIdentifier: "chapter-row-3",
      onSelect: {}
    )

    #expect(completed.title == "Chapter 3: The Signal")
    #expect(completed.timingText == "00:42 · 18 min")
    #expect(completed.isCompleted)
    #expect(completed.trailingIndicatorSystemImage == "checkmark.circle.fill")
    #expect(completed.showsTrailingIndicator)
    #expect(completed.titleColorToken == .textSecondary)
    #expect(completed.accessibilityLabel == "Chapter 3, The Signal")
    #expect(
      completed.accessibilityValue == "Starts at 42 seconds, 18 minutes long, completed")
    #expect(completed.accessibilityIdentifier == "chapter-row-3")

    let withoutIndicator = ChapterRow(
      title: "Chapter 4",
      timingText: "01:00 · 12 min",
      isCurrent: false,
      isCompleted: false,
      trailingIndicatorSystemImage: nil,
      accessibilityLabel: "Chapter 4",
      accessibilityValue: "Starts at one minute, 12 minutes long",
      onSelect: {}
    )
    #expect(!withoutIndicator.showsTrailingIndicator)
  }

  @Test("chapter row marks current distinctly from completed")
  func chapterRowMarksCurrentDistinctFromCompleted() {
    let current = ChapterRow(
      title: "Chapter 2",
      timingText: "10:00 · 20 min",
      isCurrent: true,
      isCompleted: false,
      trailingIndicatorSystemImage: "waveform",
      accessibilityLabel: "Chapter 2",
      accessibilityValue: "10 minutes in, currently playing",
      onSelect: {}
    )
    let completed = ChapterRow(
      title: "Chapter 1",
      timingText: "00:00 · 10 min",
      isCurrent: false,
      isCompleted: true,
      trailingIndicatorSystemImage: "checkmark.circle.fill",
      accessibilityLabel: "Chapter 1",
      accessibilityValue: "Completed",
      onSelect: {}
    )

    #expect(current.isCurrent)
    #expect(!current.isCompleted)
    #expect(current.titleWeight == .semibold)
    #expect(current.titleColorToken == .textPrimary)
    #expect(current.indicatorUsesTint)
    #expect(completed.isCompleted)
    #expect(!completed.isCurrent)
    #expect(completed.titleWeight == .regular)
    #expect(completed.titleColorToken == .textSecondary)
    #expect(!completed.indicatorUsesTint)
  }

  @Test("clock formatter normalizes non-finite and negative durations")
  func clockFormatterNormalizesUnusableDurations() {
    #expect(WhirrClockFormatting.clock(.nan) == "00:00")
    #expect(WhirrClockFormatting.clock(.infinity) == "00:00")
    #expect(WhirrClockFormatting.clock(-12) == "00:00")
    #expect(WhirrClockFormatting.clock(3_661) == "1:01:01")
  }

  @Test("chapter row exposes caller-supplied title, accessibility value, and current state")
  func chapterRowExposesCopyAndCurrentState() {
    var selected = false
    let row = ChapterRow(
      title: "Chapter 3: The Signal",
      accessibilityValue: "Starts at 42 minutes, 18 minutes long",
      isCurrent: true,
      currentIndicatorSystemImage: "checkmark",
      onSelect: { selected = true }
    )
    #expect(row.title == "Chapter 3: The Signal")
    #expect(row.accessibilityValue == "Starts at 42 minutes, 18 minutes long")
    #expect(row.isCurrent)
    row.onSelect()
    #expect(selected)
  }

  @Test("chapter row does not rely on color alone to indicate the current chapter")
  func chapterRowDoesNotUseColorOnlyStatus() {
    let current = ChapterRow(
      title: "Chapter 1", accessibilityValue: "18 minutes", isCurrent: true,
      currentIndicatorSystemImage: "checkmark", onSelect: {}
    )
    let notCurrent = ChapterRow(
      title: "Chapter 2", accessibilityValue: "20 minutes", isCurrent: false,
      currentIndicatorSystemImage: "checkmark", onSelect: {}
    )
    // The non-color cue (an explicit indicator glyph) is only present for the current chapter.
    #expect(current.isCurrent && !current.currentIndicatorSystemImage.isEmpty)
    #expect(!notCurrent.isCurrent)
  }

  @Test("chapter row meets the 44pt minimum hit target")
  func chapterRowMeetsMinimumHitTarget() {
    let row = ChapterRow(
      title: "Chapter 1", accessibilityValue: "18 minutes", isCurrent: false,
      currentIndicatorSystemImage: "checkmark", onSelect: {}
    )
    #expect(row.minimumHitTargetHeight >= WhirrMetric.minimumTouchTarget)
  }

  @Test("chapter list preserves caller-supplied chapter order for logical VoiceOver navigation")
  func chapterListPreservesOrder() {
    let rows = [
      ChapterRow(
        title: "Chapter 1", accessibilityValue: "10 minutes", isCurrent: false,
        currentIndicatorSystemImage: "checkmark", onSelect: {}),
      ChapterRow(
        title: "Chapter 2", accessibilityValue: "12 minutes", isCurrent: true, currentIndicatorSystemImage: "checkmark",
        onSelect: {}),
      ChapterRow(
        title: "Chapter 3", accessibilityValue: "9 minutes", isCurrent: false, currentIndicatorSystemImage: "checkmark",
        onSelect: {}),
    ]
    let list = ChapterListView(rows: rows)
    #expect(list.rows.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 3"])
  }

  // MARK: - Buffering / recoverable-error / offline / recovering-session states

  @Test(
    "playback status banner renders distinct caller-supplied copy and icon per status kind (no color-only status)",
    arguments: [
      (PlaybackStatusKind.buffering, "arrow.triangle.2.circlepath"),
      (PlaybackStatusKind.recoverableError, "exclamationmark.triangle"),
      (PlaybackStatusKind.offline, "wifi.slash"),
      (PlaybackStatusKind.recoveringSession, "clock.arrow.circlepath"),
    ]
  )
  func playbackStatusBannerRendersDistinctCopyPerKind(kind: PlaybackStatusKind, systemImage: String) {
    let banner = PlaybackStatusBanner(
      kind: kind, title: "Status title", message: "Status message", systemImage: systemImage
    )
    #expect(banner.kind == kind)
    #expect(banner.systemImage == systemImage)
    #expect(banner.accessibilityLabel == "Status title. Status message")
  }

  @Test("an empty message is dropped - a title-only banner (e.g. Buffering) reads as just the title")
  func playbackStatusBannerOmitsAbsentMessageFromAccessibilityLabel() {
    let banner = PlaybackStatusBanner(
      kind: .buffering, title: "Buffering", message: "", systemImage: "arrow.triangle.2.circlepath"
    )
    #expect(banner.accessibilityLabel == "Buffering")
  }

  @Test("playback status banner icons differ per status kind, so status is never color-only")
  func playbackStatusBannerIconsDifferPerKind() {
    let icons: [PlaybackStatusKind: String] = [
      .buffering: "arrow.triangle.2.circlepath",
      .recoverableError: "exclamationmark.triangle",
      .offline: "wifi.slash",
      .recoveringSession: "clock.arrow.circlepath",
    ]
    let distinctIcons = Set(icons.values)
    #expect(distinctIcons.count == PlaybackStatusKind.allCases.count)
  }

  @Test("playback status banner supports an optional caller-supplied retry action")
  func playbackStatusBannerSupportsOptionalRetryAction() {
    var retried = false
    let banner = PlaybackStatusBanner(
      kind: .recoverableError, title: "Couldn't sync progress", message: "Check your connection and try again.",
      systemImage: "exclamationmark.triangle", retryTitle: "Try Again", retryAction: { retried = true }
    )
    #expect(banner.retryTitle == "Try Again")
    banner.retryAction?()
    #expect(retried)
  }

  @Test("playback status banner allows no retry action")
  func playbackStatusBannerAllowsNoRetryAction() {
    let banner = PlaybackStatusBanner(
      kind: .offline, title: "You're offline", message: "Showing what was last synced.", systemImage: "wifi.slash"
    )
    #expect(banner.retryTitle == nil)
    #expect(banner.retryAction == nil)
  }

  // MARK: - Structural snapshots (semantic, non-image, via `.dump`)

  @Test("playback status banner semantic snapshot captures only caller-supplied copy")
  func playbackStatusBannerSemanticSnapshot() {
    let banner = PlaybackStatusBanner(
      kind: .buffering, title: "Buffering", message: "Catching up on your connection.",
      systemImage: "arrow.triangle.2.circlepath"
    )
    assertSnapshot(of: banner, as: .dump)
  }

  @Test("chapter row semantic snapshot captures only caller-supplied copy")
  func chapterRowSemanticSnapshot() {
    let row = ChapterRow(
      title: "Chapter 3: The Signal", accessibilityValue: "Starts at 42 minutes, 18 minutes long",
      isCurrent: true, currentIndicatorSystemImage: "checkmark", onSelect: {}
    )
    assertSnapshot(of: row, as: .dump)
  }
}
