import SwiftUI

/// The full transport cluster: skip-back, play/pause, skip-forward. Stateless; every label, hint,
/// and icon is caller-supplied (ARCHITECTURE.md).
///
/// Play/pause is the filled primary action; the seconds-scale skips stay as bare symbols. The
/// rarer chapter jumps belong beside the chapter label rather than competing in this row.
public struct TransportControlsView: View {
  public let isPlaying: Bool
  public let playPauseAccessibilityLabel: String
  public let playPauseSystemImage: String
  public let skipBackAccessibilityLabel: String
  public let skipBackAccessibilityHint: String
  public let skipBackSystemImage: String
  public let skipForwardAccessibilityLabel: String
  public let skipForwardAccessibilityHint: String
  public let skipForwardSystemImage: String
  public let onPlayPauseTap: () -> Void
  public let onSkipBackTap: () -> Void
  public let onSkipForwardTap: () -> Void
  /// Fill for the play/pause disc, the focal control. The glyph is knocked out of it, so any fill
  /// colour costs the glyph no contrast. Ambient callers pass their page's ink, making
  /// disc-against-page the ratio of text-against-page at its brightest rung. Skips stay `.primary`.
  public let playPauseFill: Color

  public let playPauseButtonSize: CGFloat = PlayerMetric.transportPrimaryButtonSize
  public let skipButtonSize: CGFloat = PlayerMetric.transportSecondaryButtonSize
  public let playPauseDiscSize: CGFloat = PlayerMetric.transportPrimaryDiscSize
  public let playPauseSymbolSize: CGFloat = PlayerMetric.transportPrimarySymbolSize
  public let skipSymbolSize: CGFloat = PlayerMetric.transportSecondarySymbolSize

  /// VoiceOver order matches the visual left-to-right layout. Pure `Double`s so the order is
  /// testable without a renderer.
  public let skipBackSortPriority: Double = 2
  public let playPauseSortPriority: Double = 1
  public let skipForwardSortPriority: Double = 0

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(
    isPlaying: Bool,
    playPauseAccessibilityLabel: String,
    playPauseSystemImage: String,
    skipBackAccessibilityLabel: String,
    skipBackAccessibilityHint: String,
    skipBackSystemImage: String,
    skipForwardAccessibilityLabel: String,
    skipForwardAccessibilityHint: String,
    skipForwardSystemImage: String,
    onPlayPauseTap: @escaping () -> Void,
    onSkipBackTap: @escaping () -> Void,
    onSkipForwardTap: @escaping () -> Void,
    playPauseFill: Color = .primary
  ) {
    self.isPlaying = isPlaying
    self.playPauseAccessibilityLabel = playPauseAccessibilityLabel
    self.playPauseSystemImage = playPauseSystemImage
    self.skipBackAccessibilityLabel = skipBackAccessibilityLabel
    self.skipBackAccessibilityHint = skipBackAccessibilityHint
    self.skipBackSystemImage = skipBackSystemImage
    self.skipForwardAccessibilityLabel = skipForwardAccessibilityLabel
    self.skipForwardAccessibilityHint = skipForwardAccessibilityHint
    self.skipForwardSystemImage = skipForwardSystemImage
    self.onPlayPauseTap = onPlayPauseTap
    self.onSkipBackTap = onSkipBackTap
    self.onSkipForwardTap = onSkipForwardTap
    self.playPauseFill = playPauseFill
  }

  public var body: some View {
    HStack(spacing: WhirrSpacing.xLarge) {
      transportButton(
        systemImage: skipBackSystemImage, symbolSize: skipSymbolSize, frameSize: skipButtonSize,
        action: onSkipBackTap
      )
      .accessibilityLabel(skipBackAccessibilityLabel)
      .accessibilityHint(skipBackAccessibilityHint)
      .accessibilitySortPriority(skipBackSortPriority)

      playPauseButton
        .accessibilityLabel(playPauseAccessibilityLabel)
        .accessibilitySortPriority(playPauseSortPriority)

      transportButton(
        systemImage: skipForwardSystemImage, symbolSize: skipSymbolSize, frameSize: skipButtonSize,
        action: onSkipForwardTap
      )
      .accessibilityLabel(skipForwardAccessibilityLabel)
      .accessibilityHint(skipForwardAccessibilityHint)
      .accessibilitySortPriority(skipForwardSortPriority)
    }
  }

  /// The focal control: a filled disc in the caller's colour with the glyph punched through it, so
  /// what reads as "play" is the page itself showing through, rather than ink laid on ink. The
  /// punch-through is why the disc needs no contrast check of its own: there is no second colour
  /// inside it that could fail against the first.
  private var playPauseButton: some View {
    Button(action: onPlayPauseTap) {
      Circle()
        .fill(playPauseFill)
        .frame(width: playPauseDiscSize, height: playPauseDiscSize)
        .overlay {
          Image(systemName: playPauseSystemImage)
            .font(.system(size: playPauseSymbolSize, weight: .semibold))
            .contentTransition(
              reduceMotion
                ? .identity
                : .symbolEffect(
                  .replace, options: .speed(PlayerMetric.transportSymbolTransitionSpeed))
            )
            .blendMode(.destinationOut)
        }
        // Confines the knock-out to the disc; without it the glyph would cut a hole through
        // everything behind the cluster, ambient background included.
        .compositingGroup()
        .frame(width: playPauseButtonSize, height: playPauseButtonSize)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    // The transition above only runs inside an animated transaction, and the first tap on a title
    // this device is not already playing starts a session asynchronously, outside the tap's own
    // transaction (where a later tap's synchronous toggle lands). Without this the glyph would snap
    // once and swap from then on.
    .animation(reduceMotion ? nil : PlayerMetric.transportIntentAnimation, value: isPlaying)
  }

  private func transportButton(
    systemImage: String, symbolSize: CGFloat, frameSize: CGFloat, tint: Color? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: symbolSize, weight: .semibold))
        .contentTransition(
          reduceMotion
            ? .identity
            : .symbolEffect(.replace, options: .speed(PlayerMetric.transportSymbolTransitionSpeed))
        )
        .frame(width: frameSize, height: frameSize)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(tint ?? .primary)
  }
}
