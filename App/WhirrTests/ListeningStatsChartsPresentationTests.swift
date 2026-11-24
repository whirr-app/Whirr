import ABSApi
import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// The Stats screen's media split, year heatmap and ring, derived without rendering.
@Suite("Listening stats charts presentation")
struct ListeningStatsChartsPresentationTests {
  private typealias P = ListeningStatsChartsPresentation

  // MARK: - Media kinds

  @Test("a catalogued item's category decides its side of the split")
  func mediaKinds() {
    #expect(P.kind(of: nil) == .other)
    #expect(P.kind(of: Self.item("book", category: .audiobook)) == .books)
    #expect(P.kind(of: Self.item("ebook", category: .ebook)) == .books)
    #expect(P.kind(of: Self.item("pod", category: .podcast)) == .podcasts)
  }

  @Test("the split sums each kind, omits empty kinds and keeps books first")
  func mediaSplit() {
    let catalogued = Self.catalogue([
      "book": .audiobook, "pod": .podcast, "pod2": .podcast,
    ])
    let shares = P.mediaSplit(
      [
        .init(serverItemId: "book", title: "A Book", author: nil, seconds: 600),
        .init(serverItemId: "pod", title: "A Show", author: nil, seconds: 300),
        .init(serverItemId: "pod2", title: "Another Show", author: nil, seconds: 100),
        .init(serverItemId: "gone", title: "Unsynced", author: nil, seconds: 100),
      ],
      catalogued: catalogued)

    #expect(shares.map(\.kind) == [.books, .podcasts, .other])
    #expect(shares.map(\.seconds) == [600, 400, 100])
    let total: Double = 1_100
    let expected: [Double] = [600 / total, 400 / total, 100 / total]
    #expect(shares.map(\.fraction) == expected)
  }

  @Test("kinds without listening are left out of the split")
  func mediaSplitOmitsEmptyKinds() {
    let shares = P.mediaSplit(
      [.init(serverItemId: "book", title: "A Book", author: nil, seconds: 600)],
      catalogued: Self.catalogue(["book": .audiobook]))

    #expect(shares.map(\.kind) == [.books])
    #expect(shares.first?.fraction == 1)
  }

  @Test("no titles at all is an empty split")
  func mediaSplitEmpty() {
    #expect(P.mediaSplit([], catalogued: { _ in nil }).isEmpty)
  }

  @Test("each kind's label comes from the stats copy")
  func mediaLabels() {
    #expect(P.label(for: .books) == ListeningStatsCopy.booksLabel)
    #expect(P.label(for: .podcasts) == ListeningStatsCopy.podcastsLabel)
    #expect(P.label(for: .other) == ListeningStatsCopy.otherLabel)
  }

  // MARK: - Title tabs

  @Test("a kind's rows bar against that kind's leader, limited to the top rows")
  func titleRowsByKind() {
    let catalogued = Self.catalogue([
      "book-a": .audiobook, "book-b": .audiobook, "book-c": .audiobook, "pod": .podcast,
    ])
    let titles: [ListeningStatsSnapshot.Title] = [
      .init(serverItemId: "book-a", title: "Book A", author: nil, seconds: 1_000),
      .init(serverItemId: "pod", title: "Show", author: nil, seconds: 800),
      .init(serverItemId: "gone", title: "Unsynced", author: nil, seconds: 500),
      .init(serverItemId: "book-b", title: "Book B", author: nil, seconds: 200),
      .init(serverItemId: "book-c", title: "Book C", author: nil, seconds: 0),
    ]

    let books = ListeningStatsScreenPresentation.titleRows(
      titles, catalogued: catalogued, kind: .books, limit: 5)
    #expect(books.map(\.id) == ["book-a", "book-b", "book-c"])
    #expect(books.map(\.share) == [1, 0.2, 0])

    let podcasts = ListeningStatsScreenPresentation.titleRows(
      titles, catalogued: catalogued, kind: .podcasts, limit: 5)
    #expect(podcasts.map(\.id) == ["pod"])
    #expect(podcasts.map(\.share) == [1])

    let topBook = ListeningStatsScreenPresentation.titleRows(
      titles, catalogued: catalogued, kind: .books, limit: 1)
    #expect(topBook.map(\.id) == ["book-a"])
  }

  @Test("uncatalogued titles are in no tab but still marked other in the full list")
  func titleRowsOtherKind() {
    let catalogued = Self.catalogue(["book": .audiobook])
    let titles: [ListeningStatsSnapshot.Title] = [
      .init(serverItemId: "book", title: "Book", author: nil, seconds: 600),
      .init(serverItemId: "gone", title: "Unsynced", author: nil, seconds: 300),
    ]
    let rows = ListeningStatsScreenPresentation.titleRows(titles, catalogued: catalogued)

    #expect(rows.map(\.kind) == [.books, .other])
    #expect(
      ListeningStatsScreenPresentation.titleRows(
        titles, catalogued: catalogued, kind: .books, limit: 5
      ).map(\.id) == ["book"])
    #expect(
      ListeningStatsScreenPresentation.titleRows(
        titles, catalogued: catalogued, kind: .podcasts, limit: 5
      ).isEmpty)
  }

  // MARK: - Heatmap

  @Test("the grid ends today, leaves the rest of today's week empty and flags before-history")
  func heatmapWeeks() {
    let weeks = P.heatmapWeeks(Self.summary(days: Self.heatmapDays), weeks: 2, calendar: Self.calendar)

    #expect(weeks.count == 2)
    #expect(weeks.allSatisfy { $0.count == 7 })
    #expect(weeks[1][3]?.date == Self.today)
    #expect(weeks[1][3]?.level == 4)
    #expect(weeks[1][4] == nil)
    #expect(weeks[1][5] == nil)
    #expect(weeks[1][6] == nil)
    // 26 Oct 2026 is the Monday of the first column, before the snapshot begins.
    #expect(weeks[0][0]?.isBeforeHistory == true)
    #expect(weeks[0][4]?.isBeforeHistory == false)
    #expect(weeks[0][4]?.level == 0)
    #expect(weeks[0][5]?.level == 0)
    #expect(weeks[1][0]?.level == 1)
    #expect(weeks[1][1]?.level == 2)
    #expect(weeks[1][2]?.level == 3)
  }

  @Test("levels split the window's listened days into quartiles")
  func heatmapQuartileLevels() {
    let weeks = P.heatmapWeeks(Self.summary(days: Self.heatmapDays), weeks: 1, calendar: Self.calendar)
    let levels = weeks.flatMap { $0 }.compactMap { $0 }.map(\.level)

    // 60, 120, 300 and 600 seconds rank 1...4 across four listened days.
    #expect(levels.filter { $0 == 1 }.count == 1)
    #expect(levels.filter { $0 == 2 }.count == 1)
    #expect(levels.filter { $0 == 3 }.count == 1)
    #expect(levels.filter { $0 == 4 }.count == 1)
  }

  @Test("a single listened day takes the darkest level")
  func heatmapSingleDay() {
    let weeks = P.heatmapWeeks(
      Self.summary(days: ["2026-11-05": 600]), weeks: 1, calendar: Self.calendar)

    #expect(weeks.count == 1)
    #expect(weeks[0][3]?.level == 4)
  }

  @Test("identical days share a level")
  func heatmapTies() {
    let weeks = P.heatmapWeeks(
      Self.summary(days: [
        "2026-11-02": 60, "2026-11-03": 120, "2026-11-04": 600, "2026-11-05": 600,
      ]),
      weeks: 1, calendar: Self.calendar)

    #expect(weeks[0][0]?.level == 1)
    #expect(weeks[0][1]?.level == 2)
    #expect(weeks[0][2]?.level == 4)
    #expect(weeks[0][3]?.level == 4)
  }

  @Test("a window wider than the record is clamped to the record's weeks")
  func heatmapClampsWeeks() {
    #expect(P.heatmapWeeks(Self.summary(), weeks: 100, calendar: Self.calendar).count == 53)
    #expect(P.heatmapWeeks(Self.summary(), weeks: 0, calendar: Self.calendar).isEmpty)
  }

  @Test("month labels sit on the column a month first appears, skipping crowding")
  func monthLabels() {
    let weeks = P.heatmapWeeks(Self.summary(), weeks: 10, calendar: Self.calendar)
    let labels = P.monthLabels(for: weeks, calendar: Self.calendar)

    // The grid starts Monday 31 August 2026; September's first column is too near August's.
    #expect(labels.map { $0.column } == [0, 5, 9])
    #expect(labels.map { $0.label } == ["Aug", "Oct", "Nov"])
  }

  // MARK: - Ring

  @Test("the ring is today against the 30-day rate, and empty under a minute a day")
  func todayProgress() {
    #expect(P.todayProgress(Self.summary()) == 0)

    let thirtyDays = Self.summary(days: Self.thirtyDays(today: 300))
    let expected = 300.0 / 590
    #expect(abs(P.todayProgress(thirtyDays) - expected) < 1e-9)

    #expect(P.todayProgress(Self.summary(days: Self.thirtyDays(today: 3_000))) == 1)
  }

  // MARK: - Fixtures

  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    calendar.firstWeekday = 2
    return calendar
  }()

  private static let today = DateComponents(
    calendar: calendar, year: 2026, month: 11, day: 5
  ).date!

  private static let heatmapDays: [String: Double] = [
    "2026-10-30": 30, "2026-11-02": 60, "2026-11-03": 120, "2026-11-04": 300,
    "2026-11-05": 600,
  ]

  private static func item(_ id: String, category: ItemMediaCategory) -> ItemSummary {
    ItemSummary(
      serverItemId: id, mediaKind: category == .podcast ? "podcast" : "book", title: id,
      author: nil, durationSeconds: nil, category: category)
  }

  private static func catalogue(_ categories: [String: ItemMediaCategory]) -> (String) -> ItemSummary? {
    { id in categories[id].map { item(id, category: $0) } }
  }

  /// The 30 days ending today, each `600` seconds except today's `today` seconds.
  private static func thirtyDays(today todaySeconds: Double) -> [String: Double] {
    var days: [String: Double] = [:]
    for offset in 0..<30 {
      guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
      let key = String(format: "%04d-%02d-%02d", year, month, day)
      days[key] = offset == 0 ? todaySeconds : 600
    }
    return days
  }

  private static func summary(
    days: [String: Double] = ["2026-11-05": 600],
    titles: [ListeningStatsSnapshot.Title] = []
  ) -> ListeningStatsSummary {
    let snapshot = ListeningStatsSnapshot(
      fetchedAt: Date(timeIntervalSince1970: 0), totalSeconds: 600,
      days: days.sorted { $0.key < $1.key }.map { .init(date: $0.key, seconds: $0.value) },
      weekdaySeconds: [5: 600], titles: titles)
    return ListeningStatsSummary.make(
      snapshot: snapshot,
      now: DateComponents(calendar: calendar, year: 2026, month: 11, day: 5, hour: 12).date!,
      calendar: calendar)
  }
}
