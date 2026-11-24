import AppModel
import DesignSystem
import SwiftUI

/// Time saved against 1×: the total large, one bar split by source, and a legend. The caller
/// supplies each source's colour, so the Stats screen can use its fixed palette and Home can tint
/// the card with its wash's mark.
struct ListeningStatsTimeSavedCard: View {
  let totals: TimeSavedTotals
  let color: (TimeSavedSource) -> Color

  @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 10
  @ScaledMetric(relativeTo: .caption) private var swatch: CGFloat = 9

  /// The legend's figures summed, so the total never reads more than the rows beneath it.
  private var totalText: String {
    ListeningStatsSummary.durationText(seconds: ListeningStatsCopy.timeSavedShownTotal(totals))
  }

  /// Largest first, so the bar and legend read in the same order.
  private var sources: [TimeSavedSource] {
    TimeSavedSource.allCases.sorted { totals[$0] > totals[$1] }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(ListeningStatsCopy.timeSavedTitle)
          .font(WhirrTypeToken.subheadline.font)
          .foregroundStyle(WashInk.secondary)
        Text(totalText)
          .font(WhirrTypeToken.display.font)
          .foregroundStyle(.primary)
          .contentTransition(.numericText())
      }
      .accessibilityElement(children: .ignore)
      .accessibilityAddTraits(.isHeader)
      .accessibilityLabel(
        "\(ListeningStatsCopy.timeSavedTitle), \(totalText)"
      )

      bar
      legend
    }
    .padding(WhirrSpacing.xxSmall)
  }

  private var bar: some View {
    GeometryReader { proxy in
      let gap: CGFloat = 2
      let shown = sources.filter { totals[$0] > 0 }
      let width = max(0, proxy.size.width - gap * CGFloat(max(shown.count - 1, 0)))
      HStack(spacing: gap) {
        ForEach(shown, id: \.self) { source in
          Rectangle()
            .fill(color(source))
            .frame(width: width * totals[source] / max(totals.total, 1))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.primary.opacity(0.08))
      .clipShape(Capsule())
    }
    .frame(height: barHeight)
    .accessibilityHidden(true)
  }

  private var legend: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      ForEach(sources, id: \.self) { source in
        let label = ListeningStatsCopy.timeSavedSourceLabel(source)
        let value = ListeningStatsSummary.durationText(seconds: totals[source])
        HStack(spacing: WhirrSpacing.xSmall) {
          Circle()
            .fill(color(source))
            .frame(width: swatch, height: swatch)
            .accessibilityHidden(true)
          Text(label)
            .foregroundStyle(WashInk.secondary)
          Spacer(minLength: WhirrSpacing.small)
          Text(value)
            .foregroundStyle(.primary)
            .contentTransition(.numericText())
        }
        .font(WhirrTypeToken.caption.font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
      }
    }
  }
}
