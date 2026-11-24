import ABSApi
import AppModel
import Charts
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// The Stats screen: the day against its average, the books/podcasts split, the last 30 days, a
/// year heatmap, the weekday totals, time saved and the most-listened titles.
///
/// Colour is the fixed `WhirrStatsPalette`, never a cover: a cover says nothing about which figure
/// it marks, and a podcast that keeps accruing time would keep painting the page its own colour.
/// Every card is the neutral editorial card. Fetches once per visit; returning from a pushed item
/// detail does not fetch again.
struct ListeningStatsView: View {
  let model: ListeningStatsModel
  let nativePodcastsEnabled: Bool
  let coverClient: any ArtworkServing
  let catalogued: (String) -> ItemSummary?
  let onSelectItem: (ItemSummary) -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.calendar) private var calendar
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.timeSaved) private var timeSaved
  @State private var listWidth: CGFloat = 0
  @State private var hasRefreshed = false
  /// Nil until the reader picks a tab, so the screen opens on whichever side has more listening.
  @State private var selectedKind: ListeningStatsChartsPresentation.MediaKind?
  @State private var catalogue = CatalogueLookup()

  /// The catalogue rows for one set of title ids; `ids` says which set the rows answer for.
  private struct CatalogueLookup {
    var ids: [String]? = nil
    var items: [String: ItemSummary] = [:]
  }

  private typealias MediaKind = ListeningStatsChartsPresentation.MediaKind
  private typealias MediaShare = ListeningStatsChartsPresentation.MediaShare

  static let coverSize: CGFloat = 56

  private var pageInset: CGFloat {
    ListeningStatsScreenPresentation.pageHorizontalInset(
      availableWidth: listWidth, horizontalSizeClass: horizontalSizeClass,
      baseInset: WhirrSpacing.medium)
  }

  init(
    model: ListeningStatsModel,
    nativePodcastsEnabled: Bool,
    coverClient: any ArtworkServing,
    catalogued: @escaping (String) -> ItemSummary?,
    onSelectItem: @escaping (ItemSummary) -> Void
  ) {
    self.model = model
    self.nativePodcastsEnabled = nativePodcastsEnabled
    self.coverClient = coverClient
    self.catalogued = catalogued
    self.onSelectItem = onSelectItem
  }

  var body: some View {
    content
      .navigationTitle(ListeningStatsCopy.title)
      .navigationBarTitleDisplayMode(.inline)
      .task {
        guard hasRefreshed == false else { return }
        hasRefreshed = true
        await model.refresh(trigger: .explicit)
      }
      .refreshable { await model.refresh(trigger: .explicit) }
  }

  @ViewBuilder
  private var content: some View {
    if let summary = model.summary {
      statsList(summary)
    } else if model.isRefreshing || hasRefreshed == false {
      LoadingStateView(message: "Loading…")
    } else {
      EmptyStateView(
        title: ListeningStatsCopy.title,
        message: model.isStale ? ListeningStatsCopy.unavailableMessage : ListeningStatsCopy.emptyMessage,
        systemImage: "chart.bar")
    }
  }

  private func statsList(_ summary: ListeningStatsSummary) -> some View {
    let ids = summary.titles.map(\.serverItemId)
    let resolved = catalogue.ids == ids
    let items = catalogue.items
    let lookup: (String) -> ItemSummary? = { items[$0] }
    let split =
      resolved ? ListeningStatsChartsPresentation.mediaSplit(summary.titles, catalogued: lookup) : []
    let kind = selectedKind ?? Self.defaultKind(in: split)
    let rows =
      resolved
      ? ListeningStatsScreenPresentation.titleRows(
        summary.titles, catalogued: lookup, kind: kind, limit: 5) : []

    return List {
      ListeningStatsHeroCard(
        summary: summary,
        dots: ListeningStatsScreenPresentation.weekDots(summary, calendar: calendar),
        isStale: model.isStale
      )
      .editorialCardListRow(CoverWash.neutral, horizontalInset: pageInset)
      .listRowSeparator(.hidden)

      if split.isEmpty == false {
        ListeningStatsMediaSplitCard(shares: split, color: { Self.paletteColor(for: $0) })
          .editorialCardListRow(CoverWash.neutral, horizontalInset: pageInset)
          .listRowSeparator(.hidden)
      }

      chartCard(
        title: ListeningStatsCopy.lastThirtyDaysTitle,
        trailing: summary.lastThirtyDaysAverageSeconds >= 60
          ? ListeningStatsCopy.dailyAverage(seconds: summary.lastThirtyDaysAverageSeconds) : nil
      ) {
        dailyChart(summary)
      }
      .editorialCardListRow(CoverWash.neutral, horizontalInset: pageInset)
      .listRowSeparator(.hidden)

      chartCard(title: ListeningStatsCopy.historyTitle, trailing: nil) {
        ListeningStatsHeatmap(summary: summary)
      }
      .editorialCardListRow(CoverWash.neutral, horizontalInset: pageInset)
      .listRowSeparator(.hidden)

      chartCard(title: ListeningStatsCopy.weekdaysTitle, trailing: ListeningStatsCopy.weekdaysPeriod) {
        weekdayChart(summary.weekdays)
      }
      .editorialCardListRow(CoverWash.neutral, horizontalInset: pageInset)
      .listRowSeparator(.hidden)

      if let timeSaved {
        ListeningStatsTimeSavedCard(
          totals: timeSaved.totals, color: { Self.timeSavedColor(for: $0) }
        )
        .editorialCardListRow(CoverWash.neutral, horizontalInset: pageInset)
        .listRowSeparator(.hidden)
      }

      if resolved {
        mostListenedHeader
        mostListenedPicker(kind: kind)
      }

      if resolved, rows.isEmpty {
        Text(ListeningStatsCopy.noTitles(podcasts: kind == .podcasts))
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .listRowInsets(
            EdgeInsets(
              top: WhirrSpacing.xSmall, leading: pageInset, bottom: WhirrSpacing.small,
              trailing: pageInset)
          )
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
      } else if resolved {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
          titleRow(row, rank: index + 1, mark: WhirrStatsPalette.tint.color)
            .editorialCardListRow(CoverWash.neutral, contentPadding: 0, horizontalInset: pageInset)
            .listRowSeparator(.hidden)
        }
      }

      footnotes(otherShare: split.contains { $0.kind == .other })
        .listRowInsets(
          EdgeInsets(
            top: WhirrSpacing.small, leading: pageInset, bottom: WhirrSpacing.large, trailing: pageInset)
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.width
    } action: { width in
      listWidth = width
    }
    // Each lookup is a synchronous catalogue read, so they run once per set of titles rather than
    // on every body evaluation.
    .task(id: ids) {
      var resolvedItems: [String: ItemSummary] = [:]
      for id in ids {
        if let item = catalogued(id) { resolvedItems[id] = item }
      }
      catalogue = CatalogueLookup(ids: ids, items: resolvedItems)
    }
    .accessibilityIdentifier(ListeningStatsAccessibilityID.screen)
  }

  /// The tab the screen opens on: the side with more listening, books when the split is empty.
  private static func defaultKind(in split: [MediaShare]) -> MediaKind {
    let counted = split.filter { $0.kind != .other }
    return counted.max { $0.seconds < $1.seconds }?.kind ?? .books
  }

  private nonisolated static func paletteColor(for kind: MediaKind) -> Color {
    switch kind {
    case .books: WhirrStatsPalette.books.color
    case .podcasts: WhirrStatsPalette.podcasts.color
    case .other: WhirrStatsPalette.muted.color
    }
  }

  private nonisolated static func timeSavedColor(for source: TimeSavedSource) -> Color {
    switch source {
    case .speed: WhirrStatsPalette.tint.color
    case .ads: WhirrStatsPalette.tint.color.opacity(0.6)
    case .silence: WhirrStatsPalette.tint.color.opacity(0.32)
    }
  }

  // MARK: - Most listened

  private var mostListenedHeader: some View {
    Text(ListeningStatsCopy.topTitlesTitle)
      .font(WhirrTypeToken.title.font)
      .foregroundStyle(WhirrColorToken.textPrimary.color)
      .accessibilityAddTraits(.isHeader)
      .padding(.top, WhirrSpacing.small)
      .listRowInsets(EdgeInsets(top: 0, leading: pageInset, bottom: 0, trailing: pageInset))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
  }

  private func mostListenedPicker(kind: MediaKind) -> some View {
    Picker(
      ListeningStatsCopy.topTitlesTitle,
      selection: Binding(
        get: { kind },
        set: { selectedKind = $0 })
    ) {
      ForEach([MediaKind.books, .podcasts], id: \.self) { option in
        Text(ListeningStatsChartsPresentation.label(for: option)).tag(option)
      }
    }
    .pickerStyle(.segmented)
    .listRowInsets(
      EdgeInsets(top: 0, leading: pageInset, bottom: WhirrSpacing.xSmall, trailing: pageInset)
    )
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }

  // MARK: - Charts

  private func chartCard<ChartContent: View>(
    title: String, trailing: String?, @ViewBuilder chart: () -> ChartContent
  ) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.small) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(.primary)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: WhirrSpacing.small)
        if let trailing {
          Text(trailing)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WashInk.secondary)
        }
      }
      chart()
    }
    .padding(WhirrSpacing.xxSmall)
  }

  private func dailyChart(_ summary: ListeningStatsSummary) -> some View {
    let days = summary.lastThirtyDays
    let today = days.last?.date
    let average = summary.lastThirtyDaysAverageSeconds
    let unit = ListeningStatsScreenPresentation.chartUnit(
      maxSeconds: max(days.map(\.seconds).max() ?? 0, average))
    return Chart {
      ForEach(days) { day in
        BarMark(
          x: .value("Day", day.date, unit: .day),
          y: .value(unit.name, unit.value(seconds: day.seconds))
        )
        .cornerRadius(3)
        .foregroundStyle(
          day.seconds >= average ? WhirrStatsPalette.tint.color : WhirrStatsPalette.muted.color
        )
        .accessibilityLabel(ListeningStatsScreenPresentation.dayAccessibilityLabel(day, calendar: calendar))
        .annotation(position: .top, spacing: WhirrSpacing.xxSmall) {
          if day.date == today, day.seconds >= 60 {
            Text(ListeningStatsSummary.durationText(seconds: day.seconds))
              .font(WhirrTypeToken.caption2.font)
              .fontWeight(.semibold)
              .foregroundStyle(.primary)
          }
        }
      }
      if average >= 60 {
        RuleMark(y: .value("Average", unit.value(seconds: average)))
          .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .foregroundStyle(WashInk.secondary)
          .accessibilityLabel(ListeningStatsCopy.dailyAverageAccessibilityLabel(seconds: average))
      }
    }
    .chartYAxis { yAxis(unit) }
    .chartXAxis {
      AxisMarks(values: .stride(by: .day, count: 7)) { _ in
        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
      }
    }
    .frame(height: chartHeight)
    .animation(reduceMotion ? nil : .smooth, value: days)
  }

  private func weekdayChart(_ totals: [ListeningStatsSummary.WeekdayTotal]) -> some View {
    let busiest = ListeningStatsScreenPresentation.busiestWeekday(totals)
    let unit = ListeningStatsScreenPresentation.chartUnit(maxSeconds: totals.map(\.seconds).max() ?? 0)
    return Chart(totals) { total in
      BarMark(
        x: .value(
          "Weekday",
          ListeningStatsScreenPresentation.weekdayName(total.weekday, calendar: calendar, short: true)),
        y: .value(unit.name, unit.value(seconds: total.seconds))
      )
      .cornerRadius(5)
      .foregroundStyle(
        total.weekday == busiest ? WhirrStatsPalette.tint.color : WhirrStatsPalette.muted.color
      )
      .accessibilityLabel(
        ListeningStatsScreenPresentation.weekdayAccessibilityLabel(total, calendar: calendar)
      )
      .annotation(position: .top, spacing: WhirrSpacing.xxSmall) {
        if total.weekday == busiest {
          Text(ListeningStatsSummary.durationText(seconds: total.seconds))
            .font(WhirrTypeToken.caption2.font)
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
        }
      }
    }
    .chartYAxis { yAxis(unit) }
    .frame(height: chartHeight)
    .animation(reduceMotion ? nil : .smooth, value: totals)
  }

  /// Three or four labelled lines, so the axis stays quiet beside the bars' own annotations.
  private func yAxis(_ unit: ListeningStatsScreenPresentation.ChartUnit) -> some AxisContent {
    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
      AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
      AxisValueLabel {
        if let number = value.as(Double.self) {
          Text(ListeningStatsScreenPresentation.chartAxisLabel(number, unit: unit))
        }
      }
    }
  }

  private var chartHeight: CGFloat {
    dynamicTypeSize.isAccessibilitySize ? 260 : 180
  }

  // MARK: - Titles

  @ViewBuilder
  private func titleRow(_ row: ListeningStatsScreenPresentation.TitleRow, rank: Int, mark: Color)
    -> some View
  {
    if let item = row.item {
      Button {
        onSelectItem(item)
      } label: {
        titleRowLabel(row, rank: rank, mark: mark)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(row.accessibilityLabel)
      .accessibilityAddTraits(.isButton)
    } else {
      titleRowLabel(row, rank: rank, mark: mark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }
  }

  private func titleRowLabel(
    _ row: ListeningStatsScreenPresentation.TitleRow, rank: Int, mark: Color
  ) -> some View {
    HStack(alignment: .center, spacing: WhirrSpacing.small) {
      Text("\(rank)")
        .font(WhirrTypeToken.title.font)
        .foregroundStyle(WashInk.secondary)
        .monospacedDigit()
        .frame(minWidth: WhirrSpacing.large)
      CoverImageView(
        itemID: row.washSubject.itemID, title: row.name, displaySize: Self.coverSize,
        client: coverClient, source: row.washSubject.artworkSource,
        revision: row.washSubject.artworkRevision
      )
      // The view takes whatever frame it is given; unframed, it fills the row.
      .frame(width: Self.coverSize, height: Self.coverSize)
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(row.name)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(.primary)
          .lineLimit(2)
        if let author = row.author {
          Text(author)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WashInk.secondary)
            .lineLimit(1)
        }
        HStack(spacing: WhirrSpacing.xSmall) {
          ListeningStatsShareBar(share: row.share, mark: mark)
          Text(row.duration)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WashInk.secondary)
            .monospacedDigit()
            .fixedSize()
        }
      }
    }
    .padding(EditorialCardListRowModifier.contentPadding)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private func footnotes(otherShare: Bool) -> some View {
    var notes = ListeningStatsScreenPresentation.footnotes(
      nativePodcastsEnabled: nativePodcastsEnabled)
    if otherShare { notes.append(ListeningStatsCopy.otherFootnote) }
    return VStack(alignment: .leading, spacing: WhirrSpacing.xSmall) {
      ForEach(notes, id: \.self) { note in
        Text(note)
      }
    }
    .font(WhirrTypeToken.caption.font)
    .foregroundStyle(WhirrColorToken.textSecondary.color)
  }
}

/// A title's time against the most-listened title's, as a bar in the stats tint. The
/// figure beside it is the information; the bar is its shape.
struct ListeningStatsShareBar: View {
  let share: Double
  let mark: Color

  @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 6

  var body: some View {
    Capsule()
      .fill(Color.primary.opacity(0.08))
      .overlay(alignment: .leading) {
        GeometryReader { proxy in
          Capsule()
            .fill(mark)
            .frame(width: share > 0 ? max(proxy.size.width * share, height) : 0)
        }
      }
      .frame(height: height)
      .accessibilityHidden(true)
  }
}

enum ListeningStatsAccessibilityID {
  static let screen = "listeningStats.screen"
}
