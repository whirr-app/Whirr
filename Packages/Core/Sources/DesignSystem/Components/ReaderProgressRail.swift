import SwiftUI

/// The reader's progress rail, for the system bottom toolbar. `PlaybackScrubber` supplies the same
/// adjustable VoiceOver and drag semantics as the audio player; the reader supplies a hairline
/// track in its own palette with a small accent playhead. The page and percentage are spoken
/// through the caller's accessibility value, and `onScrub` reports the position under the finger so
/// the caller can name the page a release would land on.
public struct ReaderProgressRail: View {
  public static let railTrackHeight: CGFloat = 1
  public static let railThumbDiameter: CGFloat = 7

  public let progressFraction: Double
  public let accessibilityLabel: String
  public let accessibilityValue: String
  public let onAdjust: (PlaybackScrubber.AdjustmentDirection) -> Void
  public let onSeek: ((Double) -> Void)?
  public let onScrub: ((ScrubPreview?) -> Void)?

  public let trackHeight: CGFloat
  public let thumbDiameter: CGFloat
  public let hitTargetHeight: CGFloat
  public let trackColor: WhirrRGBColor
  /// The fill also draws the thumb, so the rail cannot show a playhead in one colour and a fill in
  /// another.
  public let fillColor: WhirrRGBColor

  public init(
    progressFraction: Double,
    accessibilityLabel: String,
    accessibilityValue: String,
    theme: ReaderTheme,
    onAdjust: @escaping (PlaybackScrubber.AdjustmentDirection) -> Void,
    onSeek: ((Double) -> Void)? = nil,
    onScrub: ((ScrubPreview?) -> Void)? = nil
  ) {
    self.progressFraction = progressFraction
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityValue = accessibilityValue
    self.onAdjust = onAdjust
    self.onSeek = onSeek
    self.onScrub = onScrub
    self.trackHeight = Self.railTrackHeight
    self.thumbDiameter = Self.railThumbDiameter
    self.hitTargetHeight = PlayerMetric.scrubberHitTargetHeight
    self.trackColor = theme.palette.track
    self.fillColor = theme.palette.accent
  }

  public var body: some View {
    PlaybackScrubber(
      progressFraction: progressFraction,
      accessibilityLabel: accessibilityLabel,
      accessibilityValue: accessibilityValue,
      onAdjust: onAdjust,
      onSeek: onSeek,
      onScrub: onScrub,
      trackHeight: trackHeight,
      activeTrackHeight: trackHeight,
      thumbDiameter: thumbDiameter,
      hitTargetHeight: hitTargetHeight,
      trackColor: trackColor.color,
      fillColor: fillColor.color
    )
  }
}
