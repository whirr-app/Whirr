import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The hero's stat: bar and remainder while part-played, nothing otherwise. It reads the playhead
/// itself, so the views above stay out of the twice-per-second update and the draw-nothing
/// decision lives here.
///
/// Both figures come from `ItemDetailPlayButtonPresentation`, gated the same way, so the lead and
/// the bar appear and disappear together.
struct ItemDetailDurationLine: View {
  let item: ItemSummary
  let playback: PlaybackModel
  let isFinished: Bool
  let alignment: HeroColumnAlignment

  var body: some View {
    let positionSeconds = ItemDetailPlayButtonPresentation.displayedPositionSeconds(
      item: item, playback: playback)

    if let lead = ItemDetailPlayButtonPresentation.heroStatLead(
      positionSeconds: positionSeconds,
      durationSeconds: item.durationSeconds,
      isFinished: isFinished,
      playbackRate: playback.effectiveRate(for: item.serverItemId)),
      let progressFraction = ItemDetailPlayButtonPresentation.progressFraction(
        positionSeconds: positionSeconds, durationSeconds: item.durationSeconds,
        isFinished: isFinished)
    {
      ItemDetailStatLineBody(lead: lead, progressFraction: progressFraction, alignment: alignment)
    }
  }
}

/// The stat line's drawn form: the linear progress bar with its footer, whole-number completion
/// leading and the remainder trailing, shared by the audio and ebook stats. It owns its padding
/// from the credits, so drawing nothing leaves no empty band.
struct ItemDetailStatLineBody: View {
  let lead: String
  let progressFraction: Double
  let alignment: HeroColumnAlignment

  @Environment(\.ambientProgressFill) private var progressFill

  var body: some View {
    VStack(alignment: alignment.stackAlignment, spacing: WhirrSpacing.xSmall) {
      PlaybackProgressBar(
        fraction: progressFraction, tint: progressFill ?? PlaybackProgressBar.progressTint
      )
      .frame(maxWidth: .infinity)
      .accessibilityHidden(true)
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.small) {
        if let percent = ItemDetailPlayButtonPresentation.progressPercentLabel(
          fraction: progressFraction)
        {
          Text(percent)
            .foregroundStyle(WhirrMetadataProminence.tertiary.adaptiveStyle)
        }
        Spacer(minLength: WhirrSpacing.small)
        Text(lead)
          .fontWeight(.semibold)
          .foregroundStyle(WhirrMetadataProminence.heroStatLead.adaptiveStyle)
      }
      .frame(maxWidth: .infinity)
    }
    .font(WhirrTypeToken.caption.font)
    .frame(maxWidth: .infinity, alignment: alignment.frameAlignment)
    // Wider than a wrapped credit's own rows, so a long narrator list cannot look as though the
    // remainder were its last narrator.
    .padding(.top, WhirrSpacing.small)
    // Two lines for the eye, one utterance for VoiceOver: they are two halves of one fact, and
    // separate elements would put a stop between a remainder and its runtime.
    .accessibilityElement(children: .combine)
  }
}
