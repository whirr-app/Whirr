import AppModel
import DesignSystem
import SwiftUI

/// The Stats screen's hero: a ring of today against the 30-day rate, the streak, the all-time
/// figure, the week strip and the two-bar week comparison. Every figure is a fixed palette colour;
/// nothing here comes from a cover.
struct ListeningStatsHeroCard: View {
  let summary: ListeningStatsSummary
  let dots: [ListeningStatsScreenPresentation.WeekDot]
  var isStale = false

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .title2) private var ringSize: CGFloat = 96
  @ScaledMetric(relativeTo: .title2) private var ringLine: CGFloat = 9

  private var progress: Double {
    ListeningStatsChartsPresentation.todayProgress(summary)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.medium) {
      let layout =
        dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: WhirrSpacing.medium))
        : AnyLayout(HStackLayout(alignment: .top, spacing: WhirrSpacing.large))
      layout {
        ringColumn
        figures
      }

      ListeningStatsWeekStrip(dots: dots, mark: WhirrStatsPalette.tint.color)

      ListeningStatsWeekComparison(
        current: summary.lastSevenDaysSeconds,
        previous: summary.previousSevenDaysSeconds,
        currentColor: WhirrStatsPalette.tint.color,
        previousColor: WhirrStatsPalette.muted.color)

      if isStale {
        Text(ListeningStatsCopy.staleMessage)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(WhirrSpacing.xxSmall)
  }

  private var ringColumn: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      ring
      if let note = ListeningStatsCopy.todayAgainstAverage(
        today: summary.todaySeconds, average: summary.lastThirtyDaysAverageSeconds)
      {
        Text(note)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var ring: some View {
    let duration = ListeningStatsSummary.durationText(seconds: summary.todaySeconds)
    return ZStack {
      Circle()
        .stroke(Color.primary.opacity(0.08), lineWidth: ringLine)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(
          WhirrStatsPalette.tint.color,
          style: StrokeStyle(lineWidth: ringLine, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
      VStack(spacing: 0) {
        Text(duration)
          .font(WhirrTypeToken.title.font)
          .foregroundStyle(.primary)
          .monospacedDigit()
          .contentTransition(.numericText())
          .lineLimit(1)
          .minimumScaleFactor(0.5)
        Text(ListeningStatsCopy.todayLabel)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
      }
      .padding(.horizontal, ringLine)
    }
    .frame(width: ringSize, height: ringSize)
    .animation(reduceMotion ? nil : .smooth, value: progress)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(ListeningStatsCopy.todayLabel), \(duration)")
  }

  private var figures: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      streak
      allTime
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var streak: some View {
    let days = summary.streakDays
    return VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.xxSmall) {
        Image(systemName: days > 0 ? "flame.fill" : "flame")
          .foregroundStyle(
            days > 0 ? AnyShapeStyle(WhirrStatsPalette.tint.color) : AnyShapeStyle(WashInk.secondary)
          )
          .symbolEffect(.bounce, value: days)
        Text(ListeningStatsCopy.streak(days: days))
          .foregroundStyle(.primary)
          .contentTransition(.numericText())
      }
      .font(WhirrTypeToken.title.font)
      Text(ListeningStatsCopy.streakLabel)
        .font(WhirrTypeToken.subheadline.font)
        .foregroundStyle(WashInk.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(ListeningStatsCopy.streakLabel), \(ListeningStatsCopy.streak(days: days))")
  }

  private var allTime: some View {
    let value = ListeningStatsSummary.durationText(seconds: summary.totalSeconds)
    return VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      Text(value)
        .font(WhirrTypeToken.title.font)
        .foregroundStyle(.primary)
        .contentTransition(.numericText())
      Text(ListeningStatsCopy.allTimeLabel)
        .font(WhirrTypeToken.subheadline.font)
        .foregroundStyle(WashInk.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(ListeningStatsCopy.allTimeLabel), \(value)")
  }
}
