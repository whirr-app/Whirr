import Foundation
import SyncEngine
import Testing

@testable import Whirr

/// detail-screen-redesign: `ItemDetailHistoryPresentation` maps `ListeningHistoryEntry` (SyncEngine)
/// into row copy. `now`/`calendar` are injected in every test so the today/yesterday/absolute-date
/// branching is deterministic, independent of the real wall clock.
struct ItemDetailHistoryPresentationTests {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  @Test("rows preserve entry order and derive start/end/listened labels")
  func rowsDescribeSessions() {
    let now = Self.date(2026, 7, 24, 10)
    let entries = [
      ListeningHistoryEntry(
        sessionId: "s1", startedAt: now, startPosition: 65, endPosition: 3_725, listenedSeconds: 3_660)
    ]

    let rows = ItemDetailHistoryPresentation.rows(entries: entries, now: now, calendar: Self.calendar)

    #expect(rows.map(\.id) == ["s1"])
    #expect(rows[0].rangeLabel == "Started at 01:05 → ended 1:02:05")
    #expect(rows[0].listenedLabel == "1 hr 1 min listened")
    #expect(rows[0].startPosition == 65)
  }

  @Test("a session started today is labeled Today")
  func sessionToday() {
    let now = Self.date(2026, 7, 24, 15, 30)
    let entries = [
      ListeningHistoryEntry(
        sessionId: "s1", startedAt: Self.date(2026, 7, 24, 9, 0), startPosition: 0, endPosition: 10,
        listenedSeconds: 10)
    ]

    let rows = ItemDetailHistoryPresentation.rows(entries: entries, now: now, calendar: Self.calendar)

    #expect(rows[0].dateLabel.hasPrefix("Today, "))
  }

  @Test("a session started yesterday is labeled Yesterday")
  func sessionYesterday() {
    let now = Self.date(2026, 7, 24, 15, 30)
    let entries = [
      ListeningHistoryEntry(
        sessionId: "s1", startedAt: Self.date(2026, 7, 23, 21, 0), startPosition: 0, endPosition: 10,
        listenedSeconds: 10)
    ]

    let rows = ItemDetailHistoryPresentation.rows(entries: entries, now: now, calendar: Self.calendar)

    #expect(rows[0].dateLabel.hasPrefix("Yesterday, "))
  }

  @Test("a session from further back uses an absolute date, not Today/Yesterday")
  func sessionFurtherBackUsesAbsoluteDate() {
    let now = Self.date(2026, 7, 24, 15, 30)
    let entries = [
      ListeningHistoryEntry(
        sessionId: "s1", startedAt: Self.date(2026, 7, 10, 8, 0), startPosition: 0, endPosition: 10,
        listenedSeconds: 10)
    ]

    let rows = ItemDetailHistoryPresentation.rows(entries: entries, now: now, calendar: Self.calendar)

    #expect(rows[0].dateLabel.hasPrefix("Today, ") == false)
    #expect(rows[0].dateLabel.hasPrefix("Yesterday, ") == false)
  }

  @Test("rows preserve the newest-first order the model already provides")
  func rowsPreserveModelOrder() {
    let now = Self.date(2026, 7, 24, 12)
    let entries = [
      ListeningHistoryEntry(
        sessionId: "newest", startedAt: now, startPosition: 0, endPosition: 10, listenedSeconds: 10),
      ListeningHistoryEntry(
        sessionId: "oldest", startedAt: Self.date(2026, 7, 1, 12), startPosition: 0, endPosition: 10,
        listenedSeconds: 10),
    ]

    let rows = ItemDetailHistoryPresentation.rows(entries: entries, now: now, calendar: Self.calendar)

    #expect(rows.map(\.id) == ["newest", "oldest"])
  }
}
