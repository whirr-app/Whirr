import AppModel
import DesignSystem
import SwiftUI

/// The year as a grid of days: columns are weeks, rows are weekdays in the calendar's order. The
/// Stats screen scrolls it to today's end; Home shows a short, fixed slice of it.
struct ListeningStatsHeatmap: View {
  let summary: ListeningStatsSummary
  var weeks: Int = 53
  var scrolls: Bool = true
  var color: Color = WhirrStatsPalette.tint.color
  var showsFooter: Bool = true

  @Environment(\.calendar) private var calendar
  @ScaledMetric(relativeTo: .caption) private var scaledCell: CGFloat = 12
  @ScaledMetric(relativeTo: .caption) private var swatch: CGFloat = 10
  @State private var measuredWidth: CGFloat = 0

  private var gap: CGFloat {
    scrolls ? 3 : 2
  }

  /// A fixed 12pt cell while scrolling; on Home the slice shrinks to whatever the card holds, so
  /// sixteen weeks never push the card wider than the page.
  private var cellSize: CGFloat {
    guard scrolls == false, measuredWidth > 0, weeks > 0 else { return scaledCell }
    let fitted = (measuredWidth - gap * CGFloat(weeks - 1)) / CGFloat(weeks)
    return max(3, min(scaledCell, fitted))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      if scrolls {
        ScrollView(.horizontal) {
          grid
        }
        .defaultScrollAnchor(.trailing)
        .scrollIndicators(.hidden)
      } else {
        grid
          .frame(maxWidth: .infinity, alignment: .leading)
          .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
          } action: { width in
            measuredWidth = width
          }
      }
      if showsFooter {
        footer
      }
    }
  }

  private var grid: some View {
    let columns = ListeningStatsChartsPresentation.heatmapWeeks(
      summary, weeks: weeks, calendar: calendar)
    let labels = ListeningStatsChartsPresentation.monthLabels(for: columns, calendar: calendar)
    let cell = cellSize
    let gridWidth = CGFloat(columns.count) * cell + CGFloat(max(columns.count - 1, 0)) * gap
    return VStack(alignment: .leading, spacing: 3) {
      ZStack(alignment: .topLeading) {
        Color.clear
          .frame(width: gridWidth, height: 14)
        ForEach(labels.indices, id: \.self) { index in
          Text(labels[index].label)
            .font(WhirrTypeToken.caption2.font)
            .foregroundStyle(WashInk.secondary)
            .fixedSize()
            .offset(x: CGFloat(labels[index].column) * (cell + gap))
        }
      }
      HStack(alignment: .top, spacing: gap) {
        ForEach(columns.indices, id: \.self) { column in
          VStack(spacing: gap) {
            ForEach(columns[column].indices, id: \.self) { slot in
              cellView(columns[column][slot], size: cell)
            }
          }
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      ListeningStatsCopy.heatmapAccessibilityLabel(daysListened: summary.historyDaysListened))
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      Text(ListeningStatsCopy.historyCaption(daysListened: summary.historyDaysListened))
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(WashInk.secondary)
      HStack(spacing: WhirrSpacing.xxSmall) {
        Text(ListeningStatsCopy.heatmapLess)
        ForEach(0...4, id: \.self) { level in
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(level == 0 ? emptyFill : color.opacity(WhirrStatsPalette.heatLevel(level)))
            .frame(width: swatch, height: swatch)
        }
        Text(ListeningStatsCopy.heatmapMore)
      }
      .font(WhirrTypeToken.caption2.font)
      .foregroundStyle(WashInk.secondary)
      .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func cellView(_ cell: ListeningStatsChartsPresentation.HeatCell?, size: CGFloat)
    -> some View
  {
    let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
    Group {
      if let cell {
        if cell.isBeforeHistory {
          shape
            .fill(Color.clear)
            .overlay {
              shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
        } else {
          shape
            .fill(
              cell.level >= 1
                ? color.opacity(WhirrStatsPalette.heatLevel(cell.level))
                : emptyFill)
        }
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
  }

  /// A day with no listening, in the grid and as the legend's first swatch, so "Less" starts from
  /// the same faint neutral the empty days wear.
  private var emptyFill: Color {
    Color.primary.opacity(0.06)
  }
}
