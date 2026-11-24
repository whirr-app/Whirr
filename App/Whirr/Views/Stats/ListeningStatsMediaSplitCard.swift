import AppModel
import Charts
import DesignSystem
import SwiftUI

/// Books, podcasts and everything the device could not classify: the total, a donut, and one row
/// per kind. The Stats screen fills it from `WhirrStatsPalette` and gives each kind a tinted tile
/// with its time and a share bar; Home passes its wash-derived marks and the compact size, which
/// keeps only each kind's share so the carousel card stays readable.
struct ListeningStatsMediaSplitCard: View {
  let shares: [ListeningStatsChartsPresentation.MediaShare]
  let color: (ListeningStatsChartsPresentation.MediaKind) -> Color
  var compact: Bool = false
  var showsHeader: Bool = true

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @ScaledMetric(relativeTo: .title2) private var fullDonutSize: CGFloat = 112
  @ScaledMetric(relativeTo: .title2) private var compactDonutSize: CGFloat = 84
  @ScaledMetric(relativeTo: .caption) private var swatch: CGFloat = 9
  @ScaledMetric(relativeTo: .caption) private var shareBarHeight: CGFloat = 5

  private var donutSize: CGFloat {
    compact ? compactDonutSize : fullDonutSize
  }

  private var totalText: String {
    ListeningStatsSummary.durationText(seconds: shares.reduce(0) { $0 + $1.seconds })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      if showsHeader {
        header
      }
      layout {
        donut
        if compact {
          compactLegend
        } else {
          tiles
        }
      }
    }
    .padding(WhirrSpacing.xxSmall)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.small) {
        Text(ListeningStatsCopy.mediaSplitTitle)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
        if compact == false {
          Spacer(minLength: WhirrSpacing.small)
          Text(ListeningStatsCopy.mediaSplitPeriod)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WashInk.secondary)
        }
      }
      Text(totalText)
        .font(WhirrTypeToken.title.font)
        .foregroundStyle(.primary)
        .monospacedDigit()
        .contentTransition(.numericText())
        .accessibilityLabel("\(ListeningStatsCopy.mediaSplitTitle), \(totalText)")
    }
  }

  /// The donut sits beside its rows where there is room to, and above them at accessibility sizes,
  /// where rows squeezed beside artwork would wrap every label.
  private var layout: AnyLayout {
    if dynamicTypeSize.isAccessibilitySize {
      return AnyLayout(VStackLayout(alignment: .leading, spacing: WhirrSpacing.small))
    }
    return AnyLayout(HStackLayout(alignment: .center, spacing: WhirrSpacing.medium))
  }

  private var donut: some View {
    Chart(shares) { share in
      SectorMark(
        angle: .value(ListeningStatsCopy.mediaSplitTitle, share.seconds),
        innerRadius: .ratio(0.6),
        angularInset: 1.5
      )
      .cornerRadius(2)
      .foregroundStyle(color(share.kind))
    }
    .chartLegend(.hidden)
    .frame(width: donutSize, height: donutSize)
    .accessibilityHidden(true)
  }

  // MARK: - Home

  /// Label and share only; the times are in each row's accessibility label and on the Stats screen.
  private var compactLegend: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      ForEach(shares) { share in
        let label = ListeningStatsChartsPresentation.label(for: share.kind)
        HStack(spacing: WhirrSpacing.xSmall) {
          Circle()
            .fill(color(share.kind))
            .frame(width: swatch, height: swatch)
            .accessibilityHidden(true)
          Text(label)
            .foregroundStyle(WashInk.secondary)
            .lineLimit(1)
          Spacer(minLength: WhirrSpacing.small)
          Text(percentText(share))
            .foregroundStyle(.primary)
            .monospacedDigit()
        }
        .font(WhirrTypeToken.subheadline.font)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(share, label: label))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Stats screen

  private var tiles: some View {
    VStack(spacing: WhirrSpacing.xSmall) {
      ForEach(shares) { share in
        tile(share)
      }
    }
    .frame(maxWidth: .infinity)
  }

  /// One kind on a wash of its own colour: label and share, its time, and a bar as long as its
  /// share of the total.
  private func tile(_ share: ListeningStatsChartsPresentation.MediaShare) -> some View {
    let label = ListeningStatsChartsPresentation.label(for: share.kind)
    let tint = color(share.kind)
    return VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.xSmall) {
        Text(label)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
        Spacer(minLength: WhirrSpacing.xSmall)
        Text(percentText(share))
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(.primary)
          .monospacedDigit()
      }
      Text(ListeningStatsSummary.durationText(seconds: share.seconds))
        .font(WhirrTypeToken.headline.font)
        .foregroundStyle(.primary)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      shareBar(fraction: share.fraction, tint: tint)
    }
    .padding(.horizontal, WhirrSpacing.small)
    .padding(.vertical, WhirrSpacing.xSmall)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(tint.opacity(0.16))
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel(share, label: label))
  }

  private func shareBar(fraction: Double, tint: Color) -> some View {
    Capsule()
      .fill(tint.opacity(0.25))
      .frame(height: shareBarHeight)
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule()
            .fill(tint)
            .frame(width: proxy.size.width * min(max(fraction, 0), 1))
        }
      }
      .accessibilityHidden(true)
  }

  // MARK: - Copy

  private func percentText(_ share: ListeningStatsChartsPresentation.MediaShare) -> String {
    "\(Int((share.fraction * 100).rounded()))%"
  }

  private func accessibilityLabel(
    _ share: ListeningStatsChartsPresentation.MediaShare, label: String
  ) -> String {
    ListeningStatsCopy.mediaShareAccessibilityLabel(
      label: label, seconds: share.seconds, fraction: share.fraction)
  }
}
