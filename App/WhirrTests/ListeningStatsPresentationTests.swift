import ABSApi
import AppModel
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

/// Where Home's listening-stats card appears, and what the Stats screen derives without rendering.
@Suite("Listening stats presentation")
struct ListeningStatsPresentationTests {

  // MARK: - Home card

  @Test("the card is a Home section under All once a snapshot exists")
  func cardAppearsUnderAll() {
    let sections = HomeViewPresentation.sections(
      continueListening: [], recentlyAdded: [], downloaded: [], listeningStats: Self.summary(),
      filter: .all)

    #expect(sections.map(\.kind) == [.listeningStats])
    #expect(sections.first?.title == ListeningStatsCopy.title)
  }

  @Test("with no snapshot there is no card")
  func noSnapshotNoCard() {
    let sections = HomeViewPresentation.sections(
      continueListening: [], recentlyAdded: [], downloaded: [], listeningStats: nil, filter: .all)

    #expect(sections.isEmpty)
  }

  @Test(
    "the account-wide card is absent under every media filter",
    arguments: [MediaFilter.audiobooks, .podcasts, .ebooks])
  func absentUnderFilters(filter: MediaFilter) {
    let sections = HomeViewPresentation.sections(
      continueListening: [], recentlyAdded: [], downloaded: [], listeningStats: Self.summary(),
      filter: filter)

    #expect(sections.contains { $0.kind == .listeningStats } == false)
  }

  @Test("hiding the section in Settings removes the card")
  func hiddenInSettings() {
    let sections = HomeViewPresentation.sections(
      continueListening: [], recentlyAdded: [], downloaded: [], listeningStats: Self.summary(),
      filter: .all, hiddenSections: [.listeningStats])

    #expect(sections.isEmpty)
  }

  @Test("the reader's order places the card")
  func readerOrderPlacesTheCard() {
    let item = HomeItem(
      serverItemId: "item-1", title: "A Title", author: nil, category: .audiobook,
      durationSeconds: 3_600, progressSeconds: 600, isFinished: false, addedAt: nil,
      isDownloaded: false)
    let sections = HomeViewPresentation.sections(
      continueListening: [item], recentlyAdded: [], downloaded: [], listeningStats: Self.summary(),
      filter: .all, sectionOrder: HomeSectionOrder.stored([.listeningStats, .continueListening]))

    #expect(sections.map(\.kind) == [.listeningStats, .continueListening])
  }

  @Test("the card's heading opens the Stats screen route")
  func cardRoute() {
    #expect(
      HomeViewPresentation.detailRoute(for: .listeningStats, selectedFilter: .all)
        == .homeMore(section: .listeningStats, filter: .all))
  }

  @Test("the card offers no bulk selection")
  func noSelection() {
    #expect(HomeMoreSelectionPolicy.offersSelection(section: .listeningStats) == false)
  }

  // MARK: - Stats screen

  @Test("only catalogued titles carry an item to open")
  func titleNavigationOnlyForCataloguedItems() {
    let known = ItemSummary(
      serverItemId: "known", mediaKind: "book", title: "Known", author: "Ada", durationSeconds: nil,
      category: .audiobook)
    let rows = ListeningStatsScreenPresentation.titleRows(
      [
        .init(serverItemId: "known", title: "Known", author: "Ada", seconds: 3_900),
        .init(serverItemId: "gone", title: nil, author: "  ", seconds: 30),
      ],
      catalogued: { $0 == "known" ? known : nil })

    #expect(rows.map(\.item) == [known, nil])
    #expect(rows[0].accessibilityLabel == "Known, Ada, 1 hr 5 min")
    #expect(rows[1].name == ListeningStatsCopy.untitledItem)
    #expect(rows[1].author == nil)
    #expect(rows[1].accessibilityLabel == "\(ListeningStatsCopy.untitledItem), 0 min")
  }

  @Test("each title's bar is its share of the most-listened title")
  func titleShares() {
    let rows = ListeningStatsScreenPresentation.titleRows(
      [
        .init(serverItemId: "a", title: "A", author: nil, seconds: 4_000),
        .init(serverItemId: "b", title: "B", author: nil, seconds: 1_000),
        .init(serverItemId: "c", title: "C", author: nil, seconds: 0),
      ],
      catalogued: { _ in nil })

    #expect(rows.map(\.share) == [1, 0.25, 0])
  }

  @Test("a title row colours from the catalogued item's artwork, or the server item's own cover")
  func titleWashSubjects() {
    let known = ItemSummary(
      serverItemId: "known", mediaKind: "book", title: "Known", author: nil, durationSeconds: nil,
      category: .audiobook)
    let rows = ListeningStatsScreenPresentation.titleRows(
      [
        .init(serverItemId: "known", title: "Known", author: nil, seconds: 60),
        .init(serverItemId: "gone", title: "Gone", author: nil, seconds: 60),
      ],
      catalogued: { $0 == "known" ? known : nil })

    #expect(rows[0].washSubject == known.washSubject)
    #expect(rows[1].washSubject == .audiobookshelf("gone", revision: .unversioned))
  }

  @Test("the busiest weekday is the one the chart picks out; an empty week picks none")
  func busiestWeekday() {
    #expect(
      ListeningStatsScreenPresentation.busiestWeekday([
        .init(weekday: 1, seconds: 10), .init(weekday: 2, seconds: 90), .init(weekday: 3, seconds: 90),
      ]) == 2)
    #expect(
      ListeningStatsScreenPresentation.busiestWeekday([
        .init(weekday: 1, seconds: 0), .init(weekday: 2, seconds: 0),
      ]) == nil)
  }

  @Test("a chart plots minutes until its tallest bar reaches two hours, then hours")
  func chartUnit() {
    typealias P = ListeningStatsScreenPresentation
    #expect(P.chartUnit(maxSeconds: 0) == .minutes)
    #expect(P.chartUnit(maxSeconds: 7_199) == .minutes)
    #expect(P.chartUnit(maxSeconds: 7_200) == .hours)
    #expect(P.chartUnit(maxSeconds: .nan) == .minutes)
    #expect(P.ChartUnit.hours.value(seconds: 5_400) == 1.5)
    #expect(P.ChartUnit.minutes.value(seconds: 90) == 1.5)
  }

  @Test("axis labels carry their unit; zero stays bare")
  func chartAxisLabels() {
    typealias P = ListeningStatsScreenPresentation
    #expect(P.chartAxisLabel(0, unit: .hours) == "0")
    #expect(P.chartAxisLabel(30, unit: .minutes) == "30 min")
    #expect(P.chartAxisLabel(10, unit: .hours) == "10 hr")
    #expect(P.chartAxisLabel(2.5, unit: .hours) == "2.5 hr")
    #expect(P.chartAxisLabel(1_500, unit: .minutes) == "1500 min")
  }

  @Test("the week strip marks the last seven days that would count toward a streak")
  func weekStrip() {
    let summary = Self.summary(days: ["2026-10-30": 60, "2026-11-03": 59, "2026-11-05": 600])
    let dots = ListeningStatsScreenPresentation.weekDots(summary, calendar: Self.calendar)

    // 30 Oct 2026 is a Friday.
    #expect(dots.map(\.initial) == ["F", "S", "S", "M", "T", "W", "T"])
    #expect(dots.map(\.listened) == [true, false, false, false, false, false, true])
    #expect(dots.map(\.isToday) == [false, false, false, false, false, false, true])
    #expect(
      ListeningStatsScreenPresentation.weekStripAccessibilityLabel(dots)
        == "Listened on 2 of the last 7 days")
  }

  @Test("Home's card takes its colour from the first title in Continue Listening")
  func homeCardWash() {
    let item = HomeItem(
      serverItemId: "item-1", title: "A Title", author: nil, category: .audiobook,
      durationSeconds: 3_600, progressSeconds: 600, isFinished: false, addedAt: nil,
      isDownloaded: false)

    #expect(ListeningStatsScreenPresentation.homeCardWashSubject(continueListening: [item]) == item.washSubject)
    #expect(ListeningStatsScreenPresentation.homeCardWashSubject(continueListening: []) == nil)
  }

  @Test("a day's bar reads its full date and time")
  func dayLabel() {
    let calendar = Self.calendar
    let day = ListeningStatsSummary.DailyTotal(
      date: DateComponents(calendar: calendar, year: 2026, month: 11, day: 5).date!, seconds: 2_520)

    #expect(
      ListeningStatsScreenPresentation.dayAccessibilityLabel(
        day, calendar: calendar, locale: Locale(identifier: "en_US"))
        == "Thursday, November 5, 2026, 42 min")
  }

  @Test("a weekday's bar reads the whole weekday name")
  func weekdayLabel() {
    #expect(
      ListeningStatsScreenPresentation.weekdayAccessibilityLabel(
        .init(weekday: 2, seconds: 600), calendar: Self.calendar)
        == "Monday, 10 min")
    #expect(ListeningStatsScreenPresentation.weekdayName(2, calendar: Self.calendar, short: true) == "Mon")
  }

  @Test("the native-podcasts note shows only while native podcasts are on")
  func footnotes() {
    #expect(
      ListeningStatsScreenPresentation.footnotes(nativePodcastsEnabled: false)
        == [ListeningStatsCopy.dayBoundaryFootnote])
    #expect(
      ListeningStatsScreenPresentation.footnotes(nativePodcastsEnabled: true)
        == [ListeningStatsCopy.dayBoundaryFootnote, ListeningStatsCopy.nativePodcastsFootnote])
  }

  // MARK: - Fixtures

  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }()

  private static func summary(days: [String: Double] = ["2026-11-05": 600]) -> ListeningStatsSummary {
    let snapshot = ListeningStatsSnapshot(
      fetchedAt: Date(timeIntervalSince1970: 0), totalSeconds: 600,
      days: days.sorted { $0.key < $1.key }.map { .init(date: $0.key, seconds: $0.value) },
      weekdaySeconds: [5: 600], titles: [])
    return ListeningStatsSummary.make(
      snapshot: snapshot,
      now: DateComponents(calendar: calendar, year: 2026, month: 11, day: 5, hour: 12).date!,
      calendar: calendar)
  }

  // MARK: - Page width

  @Test("compact width keeps the base inset")
  func compactKeepsBaseInset() {
    #expect(
      ListeningStatsScreenPresentation.pageHorizontalInset(
        availableWidth: 390, horizontalSizeClass: .compact, baseInset: 16) == 16)
  }

  @Test("regular width centres the page at the stats measure")
  func regularBoundsPage() {
    let width: CGFloat = 1194
    let inset = ListeningStatsScreenPresentation.pageHorizontalInset(
      availableWidth: width, horizontalSizeClass: .regular, baseInset: 16)

    #expect(width - 2 * inset == ListeningStatsScreenPresentation.pageMeasure)
  }

  @Test("a regular width narrower than the measure keeps the base inset")
  func narrowRegularKeepsBaseInset() {
    #expect(
      ListeningStatsScreenPresentation.pageHorizontalInset(
        availableWidth: 500, horizontalSizeClass: .regular, baseInset: 16) == 16)
  }

  @Test("an unmeasured width keeps the base inset")
  func unmeasuredKeepsBaseInset() {
    #expect(
      ListeningStatsScreenPresentation.pageHorizontalInset(
        availableWidth: 0, horizontalSizeClass: .regular, baseInset: 16) == 16)
  }
}
