import ABSApi
import AppModel
import DesignSystem
import SwiftUI

/// One list: its covers, its name and a line about it. On the Podcasts tab the line is how many
/// episodes match, with a Play button; on the Smart Lists screen it is what the rules select.
struct SmartListRowView: View {
  enum Detail {
    case matchCount
    case rules
  }

  let list: SmartListSummary
  let coverClient: any ArtworkServing
  let detail: Detail
  let onOpen: () -> Void
  /// Play, Resume or Pause. The tap is `onPlay`; the caller decides what each state does.
  var playControl: PodcastEpisodeCardPlayControl = .start
  var onPlay: (() -> Void)?

  var body: some View {
    HStack(spacing: WhirrSpacing.small) {
      Button(action: onOpen) {
        HStack(spacing: WhirrSpacing.small) {
          SmartListCoverMosaic(episodes: list.coverEpisodes, client: coverClient)
          VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
            Text(list.name)
              .font(WhirrTypeToken.headline.font)
              .foregroundStyle(.primary)
              .multilineTextAlignment(.leading)
            if let detailText {
              Text(detailText)
                .font(WhirrTypeToken.subheadline.font)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
            }
          }
          Spacer(minLength: 0)
        }
        .frame(minHeight: WhirrMetric.minimumTouchTarget)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        SmartListsPresentation.rowAccessibilityLabel(
          name: list.name, detail: detailText, isActive: list.isActive)
      )
      .accessibilityHint(SmartListsPresentation.rowHint)
      .accessibilityAddTraits(.isButton)

      if let onPlay {
        Button(action: onPlay) {
          Image(systemName: playControl.systemImage)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: WhirrSpacing.large, height: WhirrSpacing.large)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(playControl == .start && list.matchCount == 0)
        .accessibilityLabel(
          SmartListsPresentation.playControlLabel(playControl, name: list.name))
      }
    }
  }

  private var detailText: String? {
    switch detail {
    case .matchCount: SmartListsPresentation.matchCountText(list.matchCount)
    case .rules: SmartListRuleSummary.text(for: list.rules)
    }
  }
}
