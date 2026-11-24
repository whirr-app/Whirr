import SwiftUI

/// An adjustable playback-position scrubber. Exposes an accessibility adjustable action (swipe
/// up/down in VoiceOver) and a caller-formatted accessibility value. The caller owns time or
/// reading-progress formatting (ARCHITECTURE.md: no hardcoded state copy here).
///
/// The drag picks the playhead up and carries it (`ScrubSession`) rather than jumping to the
/// finger, and reports its in-flight position through `onScrub` so the caller can show the target
/// time. An audiobook maps ten hours onto a few hundred points, so a tap-to-jump track loses the
/// listener's place on a stray touch and one with no live readout gives them no way to aim.
public struct PlaybackScrubber: View {
  /// The dynamic primary track's opacity solved against the light system surface. Dark mode uses
  /// the opposing white ink and therefore clears the same floor with room to spare.
  nonisolated public static let defaultTrackOpacity = max(
    nonTextContrastOpacity(
      foreground: WhirrRGBColor(0, 0, 0),
      over: WhirrColorToken.editorialBackground.lightRGB),
    nonTextContrastOpacity(
      foreground: WhirrRGBColor(1, 1, 1),
      over: WhirrRGBColor(0.055, 0.06, 0.075)))

  /// Which direction an accessibility adjustable-action gesture requested. A DesignSystem-owned
  /// value (rather than forwarding SwiftUI's `AccessibilityAdjustmentDirection` directly) so the
  /// caller's playback-seek logic never needs to import SwiftUI.
  public enum AdjustmentDirection: Sendable, Equatable {
    case increment
    case decrement
  }

  /// Current position as a fraction of total duration, `0...1`.
  public let progressFraction: Double
  public let accessibilityLabel: String
  public let accessibilityValue: String
  public let onAdjust: (AdjustmentDirection) -> Void
  public let onSeek: ((Double) -> Void)?
  /// Fires on every in-flight change with the position under the finger, and once with `nil` when
  /// the drag ends. The caller renders the target time from it.
  public let onScrub: ((ScrubPreview?) -> Void)?

  /// Hit-target height, independent of the thinner visual track.
  public let hitTargetHeight: CGFloat
  /// Idle capsule-track height, stretching to `activeTrackHeight` while a drag is in flight.
  /// Mirrors the system media scrubber's thumbless stretch instead of a stock `Slider` knob.
  public let visualTrackHeight: CGFloat
  public let activeTrackHeight: CGFloat
  /// An optional visible playhead. Audio leaves this `nil`; the reader supplies a small accent
  /// thumb without changing the drag session or its release semantics.
  public let thumbDiameter: CGFloat?
  /// Optional visual colors. `nil` preserves the existing primary-color audio appearance.
  public let trackColor: Color?
  public let fillColor: Color?

  /// The live drag, `nil` when no finger is down. Drives both the stretched track and the fill so
  /// scrubbing previews without seeking every frame; the single `onSeek` fires on release.
  @State private var session: ScrubSession?
  /// The released position, held until `progressFraction` catches up to it. Clearing on release
  /// instead would snap the fill back to the pre-seek position for the frames it takes the seek to
  /// round-trip through the player, so every scrub ended in a visible rubber-band.
  @State private var pendingFraction: Double?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// How close `progressFraction` must land to a released scrub before the fill hands control back
  /// to it. The seek resolves to the exact requested position, so this only has to absorb float
  /// rounding and the position ticking on while the seek lands.
  private static let settleTolerance: Double = 0.002
  /// Backstop for a release whose seek never reports back. A rejected or clamped seek would
  /// otherwise leave the fill frozen at the requested position indefinitely.
  private static let settleTimeout: Duration = .seconds(3)

  public init(
    progressFraction: Double,
    accessibilityLabel: String,
    accessibilityValue: String,
    onAdjust: @escaping (AdjustmentDirection) -> Void,
    onSeek: ((Double) -> Void)? = nil,
    onScrub: ((ScrubPreview?) -> Void)? = nil,
    trackHeight: CGFloat = PlayerMetric.scrubberVisualTrackHeight,
    activeTrackHeight: CGFloat = PlayerMetric.scrubberActiveTrackHeight,
    thumbDiameter: CGFloat? = nil,
    hitTargetHeight: CGFloat = PlayerMetric.scrubberHitTargetHeight,
    trackColor: Color? = nil,
    fillColor: Color? = nil
  ) {
    self.progressFraction = progressFraction
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityValue = accessibilityValue
    self.onAdjust = onAdjust
    self.onSeek = onSeek
    self.onScrub = onScrub
    self.hitTargetHeight = hitTargetHeight
    self.visualTrackHeight = trackHeight
    self.activeTrackHeight = activeTrackHeight
    self.thumbDiameter = thumbDiameter
    self.trackColor = trackColor
    self.fillColor = fillColor
  }

  /// What the track draws: the live drag if there is one, else a released scrub still waiting for
  /// the player to catch up, else the caller's position.
  private var displayedFraction: Double {
    let raw = session?.isEngaged == true ? session?.fraction : nil
    return Self.resolvedFraction(raw ?? pendingFraction ?? progressFraction)
  }

  public static func resolvedFraction(_ fraction: Double) -> Double {
    guard fraction.isFinite else { return 0 }
    return min(max(fraction, 0), 1)
  }

  /// How much of the track the fill covers: strictly proportional, with no minimum. A floor would
  /// look like a stalled bar on a long book (at ten hours across a phone, a few points swallows
  /// the first quarter-hour). The fill masks a full-width capsule, so a sliver still renders with
  /// the track's rounded left cap rather than as a squashed lozenge.
  public static func fillWidth(trackWidth: CGFloat, fraction: Double) -> CGFloat {
    guard trackWidth > 0, trackWidth.isFinite, fraction.isFinite else { return 0 }
    return trackWidth * CGFloat(Self.resolvedFraction(fraction))
  }

  public static func trackAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .snappy(duration: 0.24)
  }

  public var body: some View {
    GeometryReader { geometry in
      let isScrubbing = session?.isEngaged == true
      let fraction = displayedFraction
      let trackHeight = isScrubbing ? activeTrackHeight : visualTrackHeight
      // The default remains dynamic, but its opacity is the solved floor for the light system
      // surface; the dark appearance has more than this ratio because its primary ink is white.
      let resolvedTrackColor = trackColor ?? .primary.opacity(Self.defaultTrackOpacity)
      let resolvedFillColor = fillColor ?? .primary

      ZStack(alignment: .leading) {
        Capsule()
          .fill(resolvedTrackColor)
        Capsule()
          .fill(resolvedFillColor)
          .opacity(isScrubbing ? 1 : 0.82)
          .mask(alignment: .leading) {
            Rectangle()
              .scaleEffect(x: CGFloat(fraction), anchor: .leading)
          }

        if let thumbDiameter {
          Circle()
            .fill(resolvedFillColor)
            .frame(width: thumbDiameter, height: thumbDiameter)
            .offset(x: (geometry.size.width - thumbDiameter) * fraction)
        }
      }
      .frame(height: trackHeight)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(seekGesture(width: geometry.size.width))
      .animation(Self.trackAnimation(reduceMotion: reduceMotion), value: isScrubbing)
    }
    .frame(height: hitTargetHeight)
    .onChange(of: progressFraction) { _, updated in
      if let pendingFraction, abs(updated - pendingFraction) < Self.settleTolerance {
        self.pendingFraction = nil
      }
    }
    .task(id: pendingFraction) {
      guard pendingFraction != nil else { return }
      try? await Task.sleep(for: Self.settleTimeout)
      if Task.isCancelled == false { pendingFraction = nil }
    }
    .accessibilityElement()
    .accessibilityLabel(accessibilityLabel)
    .accessibilityValue(accessibilityValue)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: onAdjust(.increment)
      case .decrement: onAdjust(.decrement)
      @unknown default: break
      }
    }
  }

  /// `nil` for callers that never supplied `onSeek`. Their track stays display-only plus the
  /// adjustable action.
  private func seekGesture(width: CGFloat) -> (some Gesture)? {
    guard onSeek != nil, width > 0 else { return Optional<_ScrubDragGesture>.none }
    return _ScrubDragGesture(
      onChanged: { translation in
        var updated = session ?? ScrubSession(startFraction: progressFraction)
        updated.update(translation: translation, trackWidth: width)
        session = updated
        if updated.isEngaged {
          onScrub?(ScrubPreview(fraction: updated.fraction, speed: updated.speed))
        }
      },
      onEnded: {
        let finished = session
        session = nil
        // A drag that never engaged was a tap or a scroll, not a scrub: seeking on it is exactly
        // the accident this component exists to prevent.
        guard let finished, finished.isEngaged else { return }
        onScrub?(nil)
        pendingFraction = finished.fraction
        onSeek?(finished.fraction)
      }
    )
  }
}

/// Wraps `DragGesture` so `seekGesture` has a single concrete `some Gesture` type for both the
/// present-and-absent cases.
private struct _ScrubDragGesture: Gesture {
  let onChanged: (CGSize) -> Void
  let onEnded: () -> Void

  var body: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { onChanged($0.translation) }
      .onEnded { _ in onEnded() }
  }
}
