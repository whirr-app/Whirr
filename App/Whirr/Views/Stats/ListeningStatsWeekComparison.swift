import AppModel
import DesignSystem
import SwiftUI

/// The last seven days against the seven before, as two capsule bars scaled to the larger and the
/// copy's comparison sentence. Used by the Stats hero and Home's week card; the caller supplies
/// the two colours so a cover wash and the fixed stats palette can each tint it.
struct ListeningStatsWeekComparison: View {
  let current: Double
  let previous: Double
  let currentColor: Color
  let previousColor: Color
  var showsTitle: Bool = true

  @ScaledMetric(relativeTo: .caption) private var barHeight: CGFloat = 8

  private var peak: Double { max(current, previous) }

  private var sentence: String? {
    ListeningStatsCopy.weekComparison(current: current, previous: previous)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      if showsTitle {
        Text(ListeningStatsCopy.weekCompareTitle)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
      }
      bar(label: ListeningStatsCopy.thisWeekLabel, seconds: current, color: currentColor)
      bar(label: ListeningStatsCopy.previousWeekLabel, seconds: previous, color: previousColor)
      if let sentence {
        Text(sentence)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
      }
    }
  }

  private func bar(label: String, seconds: Double, color: Color) -> some View {
    let fraction = peak > 0 ? min(max(seconds / peak, 0), 1) : 0
    let duration = ListeningStatsSummary.durationText(seconds: seconds)
    return VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.small) {
        Text(label)
          .foregroundStyle(WashInk.secondary)
        Spacer(minLength: WhirrSpacing.small)
        Text(duration)
          .foregroundStyle(.primary)
          .monospacedDigit()
          .contentTransition(.numericText())
      }
      .font(WhirrTypeToken.caption.font)
      Capsule()
        .fill(Color.primary.opacity(0.08))
        .overlay(alignment: .leading) {
          GeometryReader { proxy in
            Capsule()
              .fill(color)
              .frame(width: fraction > 0 ? max(proxy.size.width * fraction, barHeight) : 0)
          }
        }
        .frame(height: barHeight)
        .accessibilityHidden(true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(label), \(duration)")
  }
}
