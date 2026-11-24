import SwiftUI

/// The shared linear playback indicator. Its accessibility policy is one element labelled
/// "Playback progress" whose value is the nearest whole percentage.
public struct PlaybackProgressBar: View {
  public let fraction: Double
  public let tint: Color
  public static let progressTint = WhirrColorToken.textPrimary.color

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast
  @Environment(\.isOnCoverWash) private var isOnCoverWash
  @Environment(\.drainedCoverWash) private var drainedCoverWash

  public init(fraction: Double, tint: Color = Self.progressTint) {
    self.fraction = fraction
    self.tint = tint
  }

  /// Normalises input before SwiftUI receives it: NaN is no progress, infinities follow their
  /// sign, and finite values are bounded to the progress range.
  public static func clamp(_ fraction: Double) -> Double {
    if fraction.isNaN { return 0 }
    return min(max(fraction, 0), 1)
  }

  /// The colour the bar draws in. On a dark wash the fill carries the cover's colour, and an
  /// accent bar of the same hue stops reading as the mark, so the bar takes the shared tint
  /// there. A drained wash is the exception: it hands the colour back to its marks.
  static func resolvedTint(
    _ tint: Color, colorScheme: ColorScheme, isOnWash: Bool, drainedMark: CoverWashValue?
  ) -> Color {
    WashInk.drawsDarkInk(colorScheme: colorScheme, isOnWash: isOnWash) && drainedMark == nil
      ? progressTint : tint
  }

  public var clampedFraction: Double { Self.clamp(fraction) }
  public var accessibilityLabel: String { "Playback progress" }
  public var accessibilityValueText: String {
    "\(Int((clampedFraction * 100).rounded()))%"
  }

  public var body: some View {
    ProgressView(value: clampedFraction)
      .progressViewStyle(.linear)
      .tint(
        Self.resolvedTint(
          tint, colorScheme: colorScheme, isOnWash: isOnCoverWash,
          drainedMark: WashInk.drainedMark(
            colorScheme: colorScheme, wash: drainedCoverWash,
            increasedContrast: colorSchemeContrast == .increased))
      )
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(accessibilityValueText)
  }
}
