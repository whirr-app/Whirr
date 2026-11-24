import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// Home's listening stats as a swipeable set of cards: today, the week, the books/podcasts split,
/// time saved and recent weeks. Heading and every card open the Stats screen.
/// `HomeViewPresentation.sections` omits the section until a snapshot exists. The cards wear the
/// wash of whatever Continue Listening leads with, neutral when nothing is in progress.
struct HomeListeningStatsSection: View {
  let summary: ListeningStatsSummary
  /// The device's time saved against 1×; its card is hidden under a minute.
  var timeSaved: TimeSavedTotals = .zero
  var wash: CoverWash = .neutral
  var horizontalInset: CGFloat = WhirrSpacing.medium
  /// Resolves a server title to its catalogue row, so the split can tell a book from a podcast.
  /// Defaulted for harness compositions that have no catalogue.
  var catalogued: (String) -> ItemSummary? = { _ in nil }
  let onOpen: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.calendar) private var calendar
  /// Derived once per snapshot, off `body`: the resolver reads the catalogue.
  @State private var split: [ListeningStatsChartsPresentation.MediaShare] = []

  /// How much of the next card stays on screen, so the set reads as a carousel rather than a card
  /// that happens to be clipped.
  static let cardPeek: CGFloat = 28

  var body: some View {
    VStack(alignment: .leading, spacing: HomePodcastsBrowseLayout.headerToContentSpacing) {
      BrowseSectionHeaderView(
        title: ListeningStatsCopy.title,
        accessibilityHint: ListeningStatsCopy.openHint,
        onSelect: onOpen
      )
      .padding(.horizontal, horizontalInset)

      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: WhirrSpacing.small) {
          todayCard
          weekCard
          if split.isEmpty == false {
            mediaCard
          }
          if ListeningStatsCopy.timeSavedLine(timeSaved) != nil {
            timeSavedCard
          }
          recentWeeksCard
        }
        .scrollTargetLayout()
        .fixedSize(horizontal: false, vertical: true)
      }
      .scrollTargetBehavior(.viewAligned)
      .scrollIndicators(.hidden)
      .contentMargins(.horizontal, horizontalInset, for: .scrollContent)
    }
    .task(id: summary) {
      split = ListeningStatsChartsPresentation.mediaSplit(summary.titles, catalogued: catalogued)
    }
    .accessibilityIdentifier(HomeAccessibilityID.sectionListeningStats)
  }

  // MARK: - Cards

  private var todayCard: some View {
    cardView(
      accessibilityLabel: ListeningStatsCopy.homeCardAccessibilityLabel(
        summary, timeSaved: timeSaved),
      identifier: HomeAccessibilityID.listeningStatsCard
    ) {
      VStack(alignment: .leading, spacing: WhirrSpacing.small) {
        let headline =
          dynamicTypeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: WhirrSpacing.xSmall))
          : AnyLayout(HStackLayout(alignment: .top, spacing: WhirrSpacing.small))
        headline {
          VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
            Text(ListeningStatsSummary.durationText(seconds: summary.todaySeconds))
              .font(WhirrTypeToken.display.font)
              .foregroundStyle(.primary)
              .contentTransition(.numericText())
            Text(ListeningStatsCopy.todayLabel)
              .font(WhirrTypeToken.subheadline.font)
              .foregroundStyle(WashInk.secondary)
          }
          if dynamicTypeSize.isAccessibilitySize == false { Spacer(minLength: 0) }
          ListeningStatsStreakBadge(days: summary.streakDays, mark: mark)
        }

        ListeningStatsWeekStrip(
          dots: ListeningStatsScreenPresentation.weekDots(summary, calendar: calendar), mark: mark)

        Text(
          ListeningStatsCopy.lastSevenDaysHeadline(
            ListeningStatsSummary.durationText(seconds: summary.lastSevenDaysSeconds))
        )
        .font(WhirrTypeToken.headline.font)
        .foregroundStyle(.primary)
        .contentTransition(.numericText())
      }
    }
  }

  private var weekCard: some View {
    cardView(accessibilityLabel: weekAccessibilityLabel) {
      VStack(alignment: .leading, spacing: WhirrSpacing.small) {
        Text(ListeningStatsCopy.weekCompareTitle)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
        ListeningStatsWeekComparison(
          current: summary.lastSevenDaysSeconds,
          previous: summary.previousSevenDaysSeconds,
          currentColor: mark,
          previousColor: mark.opacity(0.45),
          showsTitle: false)
      }
    }
  }

  private var mediaCard: some View {
    cardView(accessibilityLabel: mediaAccessibilityLabel, contentPadding: 0) {
      ListeningStatsMediaSplitCard(
        shares: split, color: { kind in Self.mediaColor(for: kind, mark: mark) }, compact: true,
        showsHeader: true)
    }
  }

  private var timeSavedCard: some View {
    cardView(accessibilityLabel: timeSavedAccessibilityLabel, contentPadding: 0) {
      ListeningStatsTimeSavedCard(
        totals: timeSaved, color: { source in Self.timeSavedColor(for: source, mark: mark) })
    }
  }

  private var recentWeeksCard: some View {
    let weeks = Self.recentWeeks
    let daysListened = ListeningStatsChartsPresentation.heatmapWeeks(
      summary, weeks: weeks, calendar: calendar
    )
    .joined().compactMap { $0 }.filter { $0.level > 0 }.count
    return cardView(
      accessibilityLabel: ListeningStatsCopy.recentWeeksAccessibilityLabel(
        weeks: weeks, daysListened: daysListened)
    ) {
      VStack(alignment: .leading, spacing: WhirrSpacing.small) {
        Text(ListeningStatsCopy.recentWeeksTitle(weeks: weeks))
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
        ListeningStatsHeatmap(
          summary: summary, weeks: weeks, scrolls: false, color: mark, showsFooter: false)
      }
    }
  }

  /// Enough weeks to show a habit at a glance while the cells stay a readable size on a phone.
  static let recentWeeks = 16

  // MARK: - Card chrome

  @ViewBuilder
  private func cardView<Content: View>(
    accessibilityLabel: String, identifier: String? = nil,
    contentPadding: CGFloat = WhirrSpacing.xxSmall, @ViewBuilder content: () -> Content
  ) -> some View {
    let card =
      Button(action: onOpen) {
        content()
          .padding(contentPadding)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .editorialCardSurface(wash)
          .contentShape(
            RoundedRectangle(
              cornerRadius: EditorialCardSurfaceModifier.cornerRadius, style: .continuous))
      }
      .buttonStyle(.plain)
      .containerRelativeFrame(.horizontal) { width, _ in
        max(0, width - horizontalInset * 2 - Self.cardPeek)
      }
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint(ListeningStatsCopy.openHint)

    if let identifier {
      card.accessibilityIdentifier(identifier)
    } else {
      card
    }
  }

  // MARK: - Copy and colour

  private var weekAccessibilityLabel: String {
    let headline = ListeningStatsCopy.lastSevenDaysHeadline(
      ListeningStatsSummary.durationText(seconds: summary.lastSevenDaysSeconds))
    guard
      let comparison = ListeningStatsCopy.weekComparison(
        current: summary.lastSevenDaysSeconds, previous: summary.previousSevenDaysSeconds)
    else { return "\(ListeningStatsCopy.weekCompareTitle), \(headline)" }
    return "\(ListeningStatsCopy.weekCompareTitle), \(headline), \(comparison)"
  }

  private var mediaAccessibilityLabel: String {
    let shares = split.map { share in
      ListeningStatsCopy.mediaShareAccessibilityLabel(
        label: ListeningStatsChartsPresentation.label(for: share.kind), seconds: share.seconds,
        fraction: share.fraction)
    }
    return ([ListeningStatsCopy.mediaSplitTitle] + shares).joined(separator: ", ")
  }

  private var timeSavedAccessibilityLabel: String {
    guard let line = ListeningStatsCopy.timeSavedLine(timeSaved) else {
      return ListeningStatsCopy.timeSavedTitle
    }
    return "\(ListeningStatsCopy.timeSavedTitle), \(line)"
  }

  /// The cover's colour as a mark on the card, solved to the 3:1 a graphic owes its ground. A wash
  /// with no hue answers nil, and the marks fall back to the app's ink.
  private var mark: Color {
    wash.accentColor(on: .card, minimumRatio: 3) ?? WhirrColorToken.brandInk.color
  }

  private nonisolated static func mediaColor(
    for kind: ListeningStatsChartsPresentation.MediaKind, mark: Color
  ) -> Color {
    switch kind {
    case .books: mark
    case .podcasts: mark.opacity(0.55)
    case .other: WhirrColorToken.textSecondary.color
    }
  }

  private nonisolated static func timeSavedColor(for source: TimeSavedSource, mark: Color) -> Color {
    switch source {
    case .speed: mark
    case .ads: mark.opacity(0.6)
    case .silence: mark.opacity(0.32)
    }
  }
}

/// The streak as a flame and a count. The count is text, so the flame's colour carries nothing on
/// its own.
struct ListeningStatsStreakBadge: View {
  let days: Int
  let mark: Color

  var body: some View {
    HStack(spacing: WhirrSpacing.xxSmall) {
      Image(systemName: days > 0 ? "flame.fill" : "flame")
        .foregroundStyle(days > 0 ? mark : Color.secondary)
        .symbolEffect(.bounce, value: days)
      Text(ListeningStatsCopy.streak(days: days))
        .foregroundStyle(.primary)
        .contentTransition(.numericText())
    }
    .font(WhirrTypeToken.headline.font)
    .padding(.horizontal, WhirrSpacing.small)
    .padding(.vertical, WhirrSpacing.xSmall)
    .background(Capsule().fill(.background.opacity(0.55)))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(ListeningStatsCopy.streakLabel), \(ListeningStatsCopy.streak(days: days))")
  }
}

/// The last seven days as dots: filled where the day would count toward a streak, ringed for today.
/// One accessibility element that says how many days had listening.
struct ListeningStatsWeekStrip: View {
  let dots: [ListeningStatsScreenPresentation.WeekDot]
  let mark: Color

  @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 22

  var body: some View {
    HStack(spacing: 0) {
      ForEach(dots) { dot in
        VStack(spacing: WhirrSpacing.xxSmall) {
          ZStack {
            Circle()
              .fill(dot.listened ? mark : Color.clear)
            Circle()
              .strokeBorder(dot.listened ? mark : Color.secondary, lineWidth: dot.isToday ? 2 : 1)
          }
          .frame(width: dotSize, height: dotSize)
          Text(dot.initial)
            .font(WhirrTypeToken.caption2.font)
            .fontWeight(dot.isToday ? .bold : .regular)
            .foregroundStyle(dot.isToday ? AnyShapeStyle(.primary) : AnyShapeStyle(WashInk.secondary))
        }
        .frame(maxWidth: .infinity)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(ListeningStatsScreenPresentation.weekStripAccessibilityLabel(dots))
  }
}
