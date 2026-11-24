import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// The Watch's pending-progress report is built from rows not yet uploaded: one entry per title,
/// the row the listener touched last, and only rows that carry a listen.
struct WatchPendingProgressReportBuilderTests {
  private let stamp = try! accountStamp(account: "a", server: "s")
  private let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

  @Test func oneEntryPerTitleFromTheLatestListen() throws {
    let report = try build([
      row(item: "book", position: 300, listenedAt: base),
      row(item: "book", position: 120, listenedAt: base.addingTimeInterval(60)),
    ])
    #expect(report.entries.count == 1)
    #expect(report.entry(itemID: "book", episodeID: nil)?.position == 120)
    #expect(report.entry(itemID: "book", episodeID: nil)?.lastListenedAt == base.addingTimeInterval(60))
  }

  @Test func rowsWithoutAListenAreLeftOut() throws {
    let report = try build([row(item: "book", position: 40, listenedAt: nil, listening: 0)])
    #expect(report.entries.isEmpty)
  }

  @Test func aFinishedRowIsReportedEvenWithoutListening() throws {
    let report = try build([row(item: "book", position: 100, listenedAt: nil, listening: 0, finished: true)])
    #expect(report.entry(itemID: "book", episodeID: nil)?.isFinished == true)
  }

  @Test func otherAccountsAndFeedsAreLeftOut() throws {
    let other = try accountStamp(account: "b", server: "s")
    let report = try build([
      row(item: "book", position: 40, listenedAt: base, stamp: other),
      row(selection: .nativeFeed(feedID: "feed", episodeID: "e"), position: 40, listenedAt: base),
    ])
    #expect(report.entries.isEmpty)
  }

  @Test func onlyTheNewestFiftyTitlesAreReported() throws {
    let rows = (0..<60).map {
      row(item: "book-\($0)", position: 10, listenedAt: base.addingTimeInterval(Double($0)))
    }
    let report = try build(rows)
    #expect(report.entries.count == WatchPendingProgressLimits.maxEntries)
    #expect(report.entry(itemID: "book-59", episodeID: nil) != nil)
    #expect(report.entry(itemID: "book-0", episodeID: nil) == nil)
  }

  @Test func downloadedTitlesAreUniqueAndBounded() throws {
    let downloaded: [WatchSelection] =
      (0..<120).map { .audiobookshelf(itemID: "book-\($0 % 110)", episodeID: nil) }
      + [.nativeFeed(feedID: "feed", episodeID: "e")]
    let report = try WatchPendingProgressReport(accountStamp: stamp, sequence: 1, sessions: [], downloaded: downloaded)
    #expect(report.downloaded.count == WatchProtocolVersion.maxRows)
    #expect(Set(report.downloaded).count == report.downloaded.count)
  }

  private func build(_ rows: [WatchOfflineProgressSession]) throws -> WatchPendingProgressReport {
    try WatchPendingProgressReport(accountStamp: stamp, sequence: 1, sessions: rows, downloaded: [])
  }

  private func row(
    item: String = "book", selection: WatchSelection? = nil, position: Double, listenedAt: Date?,
    listening: Double = 5, finished: Bool = false, stamp: WatchAccountStamp? = nil
  ) -> WatchOfflineProgressSession {
    WatchOfflineProgressSession(
      id: UUID(), accountStamp: stamp ?? self.stamp,
      selection: selection ?? .audiobookshelf(itemID: item, episodeID: nil), startedAt: base,
      updatedAt: base, startPosition: 0, currentPosition: position, duration: 3_600,
      timeListening: listening, isFinished: finished, lastListenedAt: listenedAt)
  }
}
