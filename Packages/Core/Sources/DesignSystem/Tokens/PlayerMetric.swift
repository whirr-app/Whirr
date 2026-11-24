import SwiftUI

/// Dynamic Type layout values for the expanded player's quick-action labels. Standard sizes mirror
/// the `PlayerMetric` token and label treatment; accessibility sizes drop the fixed
/// one-line/scaling constraints so the row can grow with its text.
public struct PlayerQuickActionLayoutValues: Sendable, Equatable {
  public let minimumHeight: CGFloat
  public let labelLineLimit: Int?
  public let minimumScaleFactor: CGFloat?

  public static func resolve(isAccessibilitySize: Bool) -> PlayerQuickActionLayoutValues {
    PlayerQuickActionLayoutValues(
      minimumHeight: isAccessibilitySize ? 72 : PlayerMetric.quickActionMinHeight,
      labelLineLimit: isAccessibilitySize ? nil : 1,
      minimumScaleFactor: isAccessibilitySize ? nil : 0.75)
  }

  /// What the line beneath a glyph draws for a given title: the title itself, or a blank line.
  ///
  /// Never absent: a line that came and went would leave the glyphs at different heights and grow
  /// the row when a timer started. A blank reserves one line of the label's own font at any
  /// Dynamic Type size, which no fixed height can promise.
  public static func labelLine(for title: String?) -> String {
    title ?? " "
  }
}

/// Player-specific layout metrics, additive to `WhirrMetric`. Every value that sizes a tappable
/// control meets or exceeds `WhirrMetric.minimumTouchTarget`; `PlayerComponentTests` checks that
/// directly so an edit can't silently shrink a control below the HIG minimum.
public enum PlayerMetric {
  /// Mini-player play/pause control. Fixed regardless of Dynamic Type so it never shrinks below
  /// the minimum hit target.
  public static let miniPlayerPlayPauseSize: CGFloat = WhirrMetric.minimumTouchTarget
  /// Mini-player cover slot. Purely visual sizing; the cover's accessibility exposure is
  /// controlled separately by `MiniPlayerView.coverAccessibilityLabel`.
  public static let miniPlayerCoverSize: CGFloat = WhirrMetric.minimumTouchTarget
  /// Mini-player tap-to-expand region (the title/subtitle block). Two lines of text can fall below
  /// the minimum at small Dynamic Type sizes and miss taps beside the glyphs, so the component
  /// pins this height and a rectangular content shape.
  public static let miniPlayerExpandTargetMinHeight: CGFloat = WhirrMetric.minimumTouchTarget

  /// Full transport cluster's primary (play/pause) hit target. Larger than the minimum so the
  /// primary action is a strong target.
  public static let transportPrimaryButtonSize: CGFloat = 76
  /// Full transport cluster's secondary (skip back/forward) hit targets.
  public static let transportSecondaryButtonSize: CGFloat = 56

  /// The play/pause disc draws inside its larger target rather than sizing the target itself.
  public static let transportPrimaryDiscSize: CGFloat = 68

  /// Transport glyph point sizes. The skips are bare symbols, so their size is the whole of their
  /// presence and stays far above body-text size; play/pause sits inside the disc above.
  public static let transportPrimarySymbolSize: CGFloat = 28
  public static let transportSecondarySymbolSize: CGFloat = 32

  /// The quick-action row beneath the transport (sleep timer, speed, audio route, up next, more).
  /// These are real controls, not a caption strip.
  public static let quickActionMinHeight: CGFloat = 54
  /// Three levers keep this row secondary to the transport: a smaller glyph, a lighter weight, and
  /// a caption label beneath rather than a title. Larger and semibold it reads as a second
  /// headline. Weight and label hold the hierarchy, so size stays moderate: 18 reads as four
  /// small marks under the 68pt disc, 22 overshoots on device, and 20 is five-eighths of the skip
  /// glyphs.
  public static let quickActionSymbolSize: CGFloat = 20
  public static let quickActionSymbolWeight: Font.Weight = .medium
  public static let quickActionLabelType: WhirrTypeToken = .caption2
  /// Glyph to the label under it. Tighter than any `WhirrSpacing` step: the two are one control,
  /// and a gap wide enough to read as two stacked elements is too wide.
  public static let quickActionLabelSpacing: CGFloat = 2

  /// How long the stock `.replace` symbol transition runs at speed 1, measured from a 60fps
  /// simulator capture of the play/pause button. `.animation(_:value:)` does not govern it; only
  /// `SymbolEffectOptions.speed` scales it.
  public static let systemSymbolReplaceDuration: Double = 0.5
  /// How long the play/pause glyph should take to swap. A symbol replace leaves the button briefly
  /// empty mid-swap, which at the stock length reads as an ignored tap.
  ///
  /// A request, not a guarantee: the effect's speed scaling saturates, and the 60fps capture
  /// measures ~0.23s of real swap at this value (0.10 also measured ~0.22s), the shortest the
  /// effect honours.
  public static let transportSymbolTransitionDuration: Double = 0.15
  /// What `transportSymbolTransitionDuration` costs in the only unit the symbol effect accepts.
  public static var transportSymbolTransitionSpeed: Double {
    systemSymbolReplaceDuration / transportSymbolTransitionDuration
  }

  /// The transaction a play/pause change travels in. A `.contentTransition` runs only inside an
  /// animated transaction, and the first tap on a title that is not yet the live session starts a
  /// session asynchronously, so its state change lands outside the tap's own transaction. Without
  /// this the glyph snaps on the first tap and swaps on every later one. The symbol effect keeps
  /// its own timing (see `systemSymbolReplaceDuration`); this only makes the change animated.
  public static var transportIntentAnimation: Animation {
    .linear(duration: transportSymbolTransitionDuration)
  }

  /// How far the expanded player's chrome sits above the physical bottom edge of the screen.
  ///
  /// Independent of the device's bottom safe-area inset: the page ignores that inset and applies
  /// this instead, so the quick actions read as the bottom of the screen the way Music's do. The
  /// hit box still reaches into the home-indicator band (`quickActionMinHeight` is 54), but the
  /// glyph and label stay clear. At accessibility Dynamic Type the page respects the whole inset
  /// instead (see `ExpandedPlayerView.ignoredContainerEdges`).
  ///
  /// At 12 the "1×" label under the speed control came within about a dozen points of the home
  /// indicator and the row read as pressed against the edge.
  /// `ExpandedPlayerView.upperLayout` distributes the remaining height upward.
  public static let chromeBottomClearance: CGFloat = 28

  /// The chrome's three vertical seams. Not `WhirrSpacing` steps: they are one region's tuned
  /// proportions, and a uniform gap is not what the design wants.
  ///
  /// The rhythm is 12/36/32 from the chrome's top edge through scrubber, transport, and quick
  /// actions, 80pt in total. The chrome's height is a budget the page's no-scroll invariant
  /// depends on, so the three are tuned against each other.
  ///
  /// They are not the gaps a listener sees: the scrubber centres a 7pt track in a 44pt hit target,
  /// adding roughly 18pt of optical clearance, so `chromeTopSeam`, the smallest, still reads as
  /// ~30pt of air below the metadata. `chromeTransportToQuickActionsSpacing` sits a hair under
  /// the seam above it: the quick actions are the footer, so the gap below the transport should
  /// not out-measure the one setting it apart from the timeline.
  public static let chromeTopSeam: CGFloat = 12
  public static let chromeScrubberToTransportSpacing: CGFloat = 36
  public static let chromeTransportToQuickActionsSpacing: CGFloat = 32

  /// Scrubber hit-target height. The visual track is thinner (`scrubberVisualTrackHeight`,
  /// growing to `scrubberActiveTrackHeight` while a drag is in flight, like the system media
  /// scrubber); the tappable region stays at the full minimum regardless.
  public static let scrubberHitTargetHeight: CGFloat = WhirrMetric.minimumTouchTarget
  public static let scrubberVisualTrackHeight: CGFloat = 7
  public static let scrubberActiveTrackHeight: CGFloat = 14

  /// Horizontal inset of the expanded player's whole metadata column (title, byline, chapter row).
  /// Ordinary page padding: the block is leading-aligned, so the overflow control at its trailing
  /// edge takes space the column has rather than a gutter reserved on both sides.
  public static let playerMetadataHorizontalPadding: CGFloat = WhirrSpacing.large

  /// How many lines the title may wrap to before it is handed to a single scrolling line.
  ///
  /// Three, because the overflow bubble costs the column 52pt of 297 on a 393pt device. Two lines
  /// at that width would push more titles onto the one-line marquee; three keep them on a line
  /// that stands still and reads in full.
  public static let metadataTitleLineBudget = 3

  /// The circle the overflow bubble draws, smaller than the target around it. At a full 44pt it
  /// stands as tall as both metadata lines beside it and reads as a second focal point next to the
  /// title; Apple Music draws the same control at 36.
  public static let metadataOverflowDiameter: CGFloat = 36
  /// What the finger aims at, and the width the title column gives up. The drawn disc is the only
  /// thing competing with the title, and the invisible margin around it costs the column nothing
  /// it can see.
  public static let metadataOverflowTargetDiameter: CGFloat = WhirrMetric.minimumTouchTarget
  public static let metadataOverflowSymbolSize: CGFloat = 14
  /// How far the target overhangs the drawn circle on one side, applied as negative trailing
  /// padding. Padding the target to the column's edge would leave the disc visibly inside the line
  /// the title's leading edge sits on, so the drawn circle aligns and the target overhangs into
  /// the empty gutter, as in Apple Music. Derived so it cannot drift from the two diameters.
  public static var metadataOverflowTargetOverhang: CGFloat {
    (metadataOverflowTargetDiameter - metadataOverflowDiameter) / 2
  }
  /// Clearance between the title column and the bubble.
  public static let metadataOverflowSpacing: CGFloat = WhirrSpacing.small

  /// Up Next row artwork. Not a control, so not sized from `minimumTouchTarget`: the row's own
  /// `selectionMinimumHeight` guarantees the hit target, and 44pt is too small to identify a show
  /// at a glance.
  public static let queueRowCoverSize: CGFloat = 56

  public static let chapterRowMinHeight: CGFloat = WhirrMetric.minimumTouchTarget
  /// Previous/next chapter sit beside the chapter label, where their visual scale can be quiet
  /// without shrinking the target. Their targets are separated by dead space so a tap near the
  /// selector cannot become a coarse chapter jump.
  public static let chapterNavigationButtonSize: CGFloat = WhirrMetric.minimumTouchTarget
  public static let chapterNavigationSymbolSize: CGFloat = 18
  public static let chapterNavigationSpacing: CGFloat = WhirrSpacing.small
  /// The selector has its own interaction floor; padding makes its visible label a more honest
  /// preview of that target without a filled treatment.
  public static let chapterSelectorButtonMinWidth: CGFloat = WhirrMetric.minimumTouchTarget
  public static let chapterSelectorHorizontalPadding: CGFloat = WhirrSpacing.xSmall
  /// The chapter row's disclosure chevron, pinned to a fixed width so the label beside it truncates
  /// at a stable point.
  public static let chapterRowChevronWidth: CGFloat = 12
  public static let chapterRowChevronSpacing: CGFloat = WhirrSpacing.xxSmall

  /// How long skip feedback remains visible after the latest skip request.
  public static let seekFeedbackSkipWindow: Duration = .milliseconds(900)
  /// Corner radius for the compact seek-feedback capsule.
  public static let seekFeedbackCornerRadius: CGFloat = 12
  /// Horizontal inset around the bubble's short duration label.
  public static let seekFeedbackHorizontalPadding: CGFloat = 8
  /// Vertical inset around the bubble's short duration label.
  public static let seekFeedbackVerticalPadding: CGFloat = 4
  /// Clearance between the bubble and the top of the scrubber's visual track.
  public static let seekFeedbackTrackGap: CGFloat = 6
}
