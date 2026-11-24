import DesignSystem
import SwiftUI

/// The speed card raised by the expanded and regular-width mini players, modelled on Apple
/// Podcasts': a grid of equal preset buttons, Use Default Speed, Custom Speed…, then Voice Boost.
///
/// A popover, not a `Menu`: a menu draws palette pickers as UIKit snapshots, which on device
/// showed no selected speed, didn't update after a tap, and sized each bubble to its own text
/// ("1" narrower than "0.95"). A speed, Use Default or Custom closes the card (the host raises
/// the custom alert after it has gone, so the grid never reflows); Voice Boost leaves it open so
/// the tick is seen to change.
///
/// Voice Boost and Trim Silences sit apart from the presets, whose heading names the pinned
/// title. For a podcast both write the show's own setting; an audiobook has no show, so its Voice
/// Boost changes the app-wide default and there is no Trim Silences row.
struct PlaybackRateSpeedCard: View {
  let kind: PlaybackRateScopePresentation.Kind
  let rate: Double
  let encodedPresets: String
  let hasRateOverride: Bool
  /// The rate a Focus is playing this title at, or nil when none governs it.
  var focusRate: Double? = nil
  let onSelectRate: (Double) -> Void
  let onClearRateOverride: () -> Void
  /// Closes the card and asks the host to raise the custom speed alert once it has gone.
  let onCustomSpeed: () -> Void
  /// The playing show, for its Voice Boost and Trim Silences rows. Nil for an audiobook, which has
  /// no show and is never trimmed.
  var showItemID: String? = nil

  @AppStorage(UserDefaultsPlaybackPreferences.voiceBoostKey) private var voiceBoostEnabled = false
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.dismiss) private var dismiss
  @Environment(\.showPlaybackEffects) private var showPlaybackEffects
  /// Wide enough for the longest preset label ("0.75×") in one line; scales with Dynamic Type so
  /// every button keeps the same width as text grows.
  @ScaledMetric(relativeTo: .body) private var buttonWidth: CGFloat = 68
  @ScaledMetric(relativeTo: .body) private var minimumCardContentWidth: CGFloat = 260

  private let gridSpacing = WhirrSpacing.xSmall

  var body: some View {
    let options = PlaybackRateMenuPresentation.options(
      encodedPresets: encodedPresets, currentRate: rate)
    let columnCount = PlaybackRateMenuPresentation.gridColumnCount(
      optionCount: options.count, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
    let gridWidth =
      CGFloat(columnCount) * buttonWidth + CGFloat(max(columnCount - 1, 0)) * gridSpacing

    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      // The presets always pin this title, and the heading says so.
      Text(PlaybackRateScopePresentation.menuHeader(kind: kind, focusRate: focusRate))
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      // A plain `Grid`, not `LazyVGrid`: a lazy grid has no ideal height to offer a popover,
      // which sized it to nothing and drew no buttons at all.
      Grid(horizontalSpacing: gridSpacing, verticalSpacing: gridSpacing) {
        ForEach(Array(stride(from: 0, to: options.count, by: max(columnCount, 1))), id: \.self) {
          start in
          GridRow {
            ForEach(options[start..<min(start + columnCount, options.count)]) { option in
              speedButton(option)
            }
          }
        }
      }
      .frame(maxWidth: .infinity)

      Divider()

      // Always present, disabled when there is nothing to clear: a popover sizes itself once, so
      // a row that appeared after the first speed was picked pushed the card's ends out of view.
      actionRow(PlaybackRateScopePresentation.useDefaultTitle, systemImage: "arrow.uturn.backward") {
        onClearRateOverride()
        dismiss()
      }
      .disabled(!hasRateOverride)

      actionRow(
        PlaybackRateScopePresentation.customSpeedTitle,
        systemImage: PlaybackRateScopePresentation.customSpeedSymbol
      ) {
        onCustomSpeed()
      }

      if let showItemID, let showPlaybackEffects {
        ShowVoiceBoostCardRow(itemID: showItemID, access: showPlaybackEffects)
        TrimSilencesCardRow(itemID: showItemID, access: showPlaybackEffects)
      } else {
        // An audiobook has no show, so its row changes the app-wide default it follows.
        EffectTickRow(
          title: VoiceBoostCopy.toggleTitle, systemImage: VoiceBoostCopy.menuSymbol,
          isOn: voiceBoostEnabled
        ) {
          voiceBoostEnabled.toggle()
        }
        .accessibilityIdentifier(PlayerAccessibilityID.rateCardVoiceBoost)
      }
    }
    .padding(WhirrSpacing.medium)
    .frame(width: max(gridWidth, minimumCardContentWidth) + WhirrSpacing.medium * 2)
    .accessibilityIdentifier(PlayerAccessibilityID.rateCard)
  }

  private func speedButton(_ option: PlaybackRateMenuPresentation.Option) -> some View {
    PresetCapsule(
      title: PlaybackRatePresetConfiguration.display(option.rate), isSelected: option.isSelected,
      width: buttonWidth
    ) {
      onSelectRate(option.rate)
      dismiss()
    }
  }

  private func actionRow(
    _ title: String, systemImage: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
